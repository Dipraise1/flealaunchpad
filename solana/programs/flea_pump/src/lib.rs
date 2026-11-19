//! FLÈA launchpad for Solana.
//!
//! A creator launches a 6-decimal token whose whole supply (1 billion) is minted into this program's vault and
//! whose mint authority is then destroyed. Anyone buys and sells against a constant-product bonding curve
//! (see `curve.rs`). Each trade pays a protocol fee and a creator fee. The creator fee is split between up to
//! five payees fixed at launch; any of them (or anyone on their behalf) can pull their share at any time.
//! When the curve's tokens are sold out the curve is complete and trading stops; the migration authority then
//! moves the raised SOL and the liquidity allocation into a DEX pool.
//!
//! Trust notes, stated plainly:
//!  * Migration is a trusted step. `migrate` hands the raised SOL and the remaining tokens to the configured
//!    migration authority, which is expected to seed a pool and burn the LP. The program cannot enforce that.
//!  * The admin can change fees and parameters for FUTURE launches only; each curve snapshots its own terms,
//!    including which wallet may migrate it.
//!  * The admin can pause new launches and buys. Sells are never pausable and touch no admin-controlled account:
//!    fees are accrued inside the curve and pulled later, so nothing the admin sets can block a holder's exit.

use anchor_lang::prelude::*;
use anchor_lang::solana_program::program_option::COption;
use anchor_lang::system_program;
use anchor_spl::associated_token::AssociatedToken;
use anchor_spl::token::spl_token::instruction::AuthorityType;
use anchor_spl::token::{self, Mint, MintTo, SetAuthority, Token, TokenAccount, Transfer};

pub mod curve;
use curve::{apply_buy, apply_sell, quote_buy, quote_sell, Reserves, BPS};

declare_id!("AnLucg19VhCKZpgWSHjoKULPT4yjN2wpNgFqG7wUS3cU");

pub const TOKEN_DECIMALS: u8 = 6;
pub const TOTAL_SUPPLY: u64 = 1_000_000_000 * 1_000_000;
pub const MAX_PROTOCOL_FEE_BPS: u16 = 200;
pub const MAX_CREATOR_FEE_BPS: u16 = 300;
pub const MAX_PAYEES: usize = 5;
pub const MAX_LAUNCH_FEE: u64 = 1_000_000_000; // 1 SOL
pub const MIN_VIRTUAL_SOL: u64 = 1_000_000_000; // 1 SOL

#[program]
pub mod flea_pump {
    use super::*;

    /// One-time setup. The signer becomes admin. It must be co-signed by the program's own keypair, which only
    /// the deployer holds, so nobody can front-run the deployer and seize the config.
    pub fn initialize(ctx: Context<Initialize>, p: ConfigParams) -> Result<()> {
        p.validate()?;
        let c = &mut ctx.accounts.config;
        c.admin = ctx.accounts.admin.key();
        c.pending_admin = Pubkey::default();
        c.fee_recipient = p.fee_recipient;
        c.migration_authority = p.migration_authority;
        c.protocol_fee_bps = p.protocol_fee_bps;
        c.max_creator_fee_bps = p.max_creator_fee_bps;
        c.launch_fee = p.launch_fee;
        c.virtual_sol = p.virtual_sol;
        c.virtual_tokens = p.virtual_tokens;
        c.curve_tokens = p.curve_tokens;
        c.paused = false;
        c.bump = ctx.bumps.config;
        Ok(())
    }

    /// Admin: change terms for future launches. Existing curves keep the terms they launched with.
    pub fn update_config(ctx: Context<AdminOnly>, p: ConfigParams, paused: bool) -> Result<()> {
        p.validate()?;
        let c = &mut ctx.accounts.config;
        c.fee_recipient = p.fee_recipient;
        c.migration_authority = p.migration_authority;
        c.protocol_fee_bps = p.protocol_fee_bps;
        c.max_creator_fee_bps = p.max_creator_fee_bps;
        c.launch_fee = p.launch_fee;
        c.virtual_sol = p.virtual_sol;
        c.virtual_tokens = p.virtual_tokens;
        c.curve_tokens = p.curve_tokens;
        c.paused = paused;
        Ok(())
    }

    /// Admin hand-over is two-step so a typo cannot lock the program.
    pub fn propose_admin(ctx: Context<AdminOnly>, new_admin: Pubkey) -> Result<()> {
        ctx.accounts.config.pending_admin = new_admin;
        Ok(())
    }

    pub fn accept_admin(ctx: Context<AcceptAdmin>) -> Result<()> {
        let c = &mut ctx.accounts.config;
        require_keys_eq!(ctx.accounts.new_admin.key(), c.pending_admin, FleaError::NotPendingAdmin);
        require_keys_neq!(c.pending_admin, Pubkey::default(), FleaError::NotPendingAdmin);
        c.admin = c.pending_admin;
        c.pending_admin = Pubkey::default();
        Ok(())
    }

    /// Launch a token. The caller has already created `mint` (6 decimals, supply 0, no freeze authority, itself
    /// as mint authority) and, if it wants one, the token's metadata. This instruction mints the whole supply
    /// into the curve's vault and destroys the mint authority, so no more can ever exist.
    ///
    /// A creator who wants to buy first adds a `buy` instruction to the same transaction: a transaction is
    /// atomic, so nobody can trade between the launch and that buy.
    pub fn create(ctx: Context<Create>, creator_fee_bps: u16, payees: Vec<PayeeInput>, max_launch_fee: u64) -> Result<()> {
        let config = &ctx.accounts.config;
        require!(!config.paused, FleaError::Paused);
        // The creator states the most they will pay, so a fee change landing first cannot overcharge them.
        require!(config.launch_fee <= max_launch_fee, FleaError::LaunchFeeChanged);
        require!(creator_fee_bps <= config.max_creator_fee_bps, FleaError::FeeTooHigh);

        let mint = &ctx.accounts.mint;
        require!(mint.decimals == TOKEN_DECIMALS, FleaError::BadMint);
        require!(mint.supply == 0, FleaError::BadMint);
        require!(mint.freeze_authority.is_none(), FleaError::BadMint);
        require!(mint.mint_authority == COption::Some(ctx.accounts.creator.key()), FleaError::BadMint);

        // Fee split: fixed at launch. No payees means the creator takes all of it.
        let mut table = [Payee::default(); MAX_PAYEES];
        let count = if payees.is_empty() {
            table[0] = Payee { wallet: ctx.accounts.creator.key(), bps: BPS as u16, owed: 0 };
            1
        } else {
            require!(payees.len() <= MAX_PAYEES, FleaError::BadPayees);
            let mut total: u64 = 0;
            for (i, p) in payees.iter().enumerate() {
                require!(p.bps > 0 && p.wallet != Pubkey::default(), FleaError::BadPayees);
                // These accounts can never be paid out to; naming one would silently burn that share.
                require!(p.wallet != ctx.accounts.curve.key() && p.wallet != ctx.accounts.vault.key() && p.wallet != ctx.accounts.mint.key(), FleaError::BadPayees);
                require!(!payees[..i].iter().any(|q| q.wallet == p.wallet), FleaError::BadPayees);
                total += p.bps as u64;
                table[i] = Payee { wallet: p.wallet, bps: p.bps, owed: 0 };
            }
            require!(total == BPS, FleaError::BadPayees);
            payees.len()
        };

        if config.launch_fee > 0 {
            system_program::transfer(
                CpiContext::new(
                    ctx.accounts.system_program.to_account_info(),
                    system_program::Transfer { from: ctx.accounts.creator.to_account_info(), to: ctx.accounts.fee_recipient.to_account_info() },
                ),
                config.launch_fee,
            )?;
        }

        token::mint_to(
            CpiContext::new(
                ctx.accounts.token_program.to_account_info(),
                MintTo { mint: ctx.accounts.mint.to_account_info(), to: ctx.accounts.vault.to_account_info(), authority: ctx.accounts.creator.to_account_info() },
            ),
            TOTAL_SUPPLY,
        )?;
        token::set_authority(
            CpiContext::new(
                ctx.accounts.token_program.to_account_info(),
                SetAuthority { current_authority: ctx.accounts.creator.to_account_info(), account_or_mint: ctx.accounts.mint.to_account_info() },
            ),
            AuthorityType::MintTokens,
            None,
        )?;

        let curve = &mut ctx.accounts.curve;
        curve.mint = ctx.accounts.mint.key();
        curve.creator = ctx.accounts.creator.key();
        curve.virtual_sol = config.virtual_sol;
        curve.virtual_tokens = config.virtual_tokens;
        curve.real_sol = 0;
        curve.real_tokens = config.curve_tokens;
        curve.protocol_fee_bps = config.protocol_fee_bps;
        curve.creator_fee_bps = creator_fee_bps;
        curve.unsettled_creator_fees = 0;
        curve.protocol_fees_owed = 0;
        curve.migration_authority = config.migration_authority;
        curve.complete = false;
        curve.migrated = false;
        curve.payees = table;
        curve.payee_count = count as u8;
        curve.created_at = Clock::get()?.unix_timestamp;
        curve.bump = ctx.bumps.curve;

        emit!(Launched { mint: curve.mint, creator: curve.creator, creator_fee_bps, payee_count: count as u8, virtual_sol: curve.virtual_sol, virtual_tokens: curve.virtual_tokens, curve_tokens: curve.real_tokens });
        Ok(())
    }

    /// Spend up to `sol_in` lamports. `min_tokens_out` bounds the PRICE: when the curve sells out mid-buy the
    /// buyer is charged less and receives less, but never at a worse rate than the one they asked for.
    pub fn buy(ctx: Context<Trade>, sol_in: u64, min_tokens_out: u64) -> Result<()> {
        require!(!ctx.accounts.config.paused, FleaError::Paused);
        let curve = &mut ctx.accounts.curve;
        require!(!curve.complete, FleaError::CurveComplete);

        let mut r = curve.reserves();
        let q = quote_buy(&r, sol_in, curve.protocol_fee_bps, curve.creator_fee_bps).ok_or(FleaError::BadAmount)?;
        // tokens_out / gross >= min_tokens_out / sol_in
        require!((q.tokens_out as u128) * (sol_in as u128) >= (min_tokens_out as u128) * (q.gross as u128), FleaError::Slippage);
        apply_buy(&mut r, &q).ok_or(FleaError::Math)?;

        // Everything the buyer pays goes into the curve account: the reserve, and both fees, which are pulled
        // out later by their owners. No trade ever pays a third account directly.
        system_program::transfer(
            CpiContext::new(ctx.accounts.system_program.to_account_info(), system_program::Transfer { from: ctx.accounts.user.to_account_info(), to: curve.to_account_info() }),
            q.gross,
        )?;

        let mint_key = curve.mint;
        let seeds: &[&[u8]] = &[b"curve", mint_key.as_ref(), &[curve.bump]];
        token::transfer(
            CpiContext::new_with_signer(
                ctx.accounts.token_program.to_account_info(),
                Transfer { from: ctx.accounts.vault.to_account_info(), to: ctx.accounts.user_tokens.to_account_info(), authority: curve.to_account_info() },
                &[seeds],
            ),
            q.tokens_out,
        )?;

        curve.set_reserves(&r);
        curve.unsettled_creator_fees = curve.unsettled_creator_fees.checked_add(q.creator_fee).ok_or(FleaError::Math)?;
        curve.protocol_fees_owed = curve.protocol_fees_owed.checked_add(q.protocol_fee).ok_or(FleaError::Math)?;
        if curve.real_tokens == 0 {
            curve.complete = true;
            emit!(Completed { mint: curve.mint, real_sol: curve.real_sol });
        }
        emit!(Traded { mint: curve.mint, user: ctx.accounts.user.key(), is_buy: true, sol: q.gross, tokens: q.tokens_out, protocol_fee: q.protocol_fee, creator_fee: q.creator_fee, virtual_sol: curve.virtual_sol, virtual_tokens: curve.virtual_tokens, real_sol: curve.real_sol, real_tokens: curve.real_tokens });
        Ok(())
    }

    /// Sell `tokens_in` back to the curve for at least `min_sol_out` lamports. Never pausable.
    pub fn sell(ctx: Context<Trade>, tokens_in: u64, min_sol_out: u64) -> Result<()> {
        let curve = &mut ctx.accounts.curve;
        require!(!curve.complete, FleaError::CurveComplete);

        let mut r = curve.reserves();
        let q = quote_sell(&r, tokens_in, curve.protocol_fee_bps, curve.creator_fee_bps).ok_or(FleaError::BadAmount)?;
        require!(q.net >= min_sol_out, FleaError::Slippage);
        apply_sell(&mut r, tokens_in, &q).ok_or(FleaError::Math)?;

        token::transfer(
            CpiContext::new(
                ctx.accounts.token_program.to_account_info(),
                Transfer { from: ctx.accounts.user_tokens.to_account_info(), to: ctx.accounts.vault.to_account_info(), authority: ctx.accounts.user.to_account_info() },
            ),
            tokens_in,
        )?;

        // The curve account is owned by this program, so its lamports are moved directly. Only the seller is
        // paid here; both fees stay in the curve to be pulled, so a sell depends on no account but the seller's.
        let curve_info = curve.to_account_info();
        let rent_floor = Rent::get()?.minimum_balance(curve_info.data_len());
        require!(curve_info.lamports().checked_sub(q.net).ok_or(FleaError::Math)? >= rent_floor, FleaError::Insolvent);
        **curve_info.try_borrow_mut_lamports()? -= q.net;
        **ctx.accounts.user.to_account_info().try_borrow_mut_lamports()? += q.net;

        curve.set_reserves(&r);
        curve.unsettled_creator_fees = curve.unsettled_creator_fees.checked_add(q.creator_fee).ok_or(FleaError::Math)?;
        curve.protocol_fees_owed = curve.protocol_fees_owed.checked_add(q.protocol_fee).ok_or(FleaError::Math)?;
        emit!(Traded { mint: curve.mint, user: ctx.accounts.user.key(), is_buy: false, sol: q.gross, tokens: tokens_in, protocol_fee: q.protocol_fee, creator_fee: q.creator_fee, virtual_sol: curve.virtual_sol, virtual_tokens: curve.virtual_tokens, real_sol: curve.real_sol, real_tokens: curve.real_tokens });
        Ok(())
    }

    /// Pay one payee their share of the creator fees. Anyone may call it; the money only ever goes to the
    /// payee's own wallet. Pull-based, so one payee that cannot receive never blocks the others.
    pub fn claim_creator_fees(ctx: Context<ClaimCreatorFees>, index: u8) -> Result<()> {
        let curve = &mut ctx.accounts.curve;
        let n = curve.payee_count as usize;
        require!((index as usize) < n, FleaError::BadPayees);
        require_keys_eq!(ctx.accounts.payee.key(), curve.payees[index as usize].wallet, FleaError::BadPayees);

        // Settle: credit every payee their share of what has accrued since the last settlement. The rounding
        // remainder stays unsettled and is shared out next time, so nothing is ever lost or over-credited.
        let pending = curve.unsettled_creator_fees;
        if pending > 0 {
            let mut credited: u64 = 0;
            for i in 0..n {
                let share = ((pending as u128) * (curve.payees[i].bps as u128) / (BPS as u128)) as u64;
                curve.payees[i].owed = curve.payees[i].owed.checked_add(share).ok_or(FleaError::Math)?;
                credited = credited.checked_add(share).ok_or(FleaError::Math)?;
            }
            curve.unsettled_creator_fees = pending.checked_sub(credited).ok_or(FleaError::Math)?;
        }

        let amount = curve.payees[index as usize].owed;
        require!(amount > 0, FleaError::NothingToClaim);
        curve.payees[index as usize].owed = 0;

        let curve_info = curve.to_account_info();
        let rent_floor = Rent::get()?.minimum_balance(curve_info.data_len());
        require!(curve_info.lamports().checked_sub(amount).ok_or(FleaError::Math)? >= rent_floor, FleaError::Insolvent);
        **curve_info.try_borrow_mut_lamports()? -= amount;
        **ctx.accounts.payee.to_account_info().try_borrow_mut_lamports()? += amount;
        emit!(CreatorFeesClaimed { mint: curve.mint, payee: ctx.accounts.payee.key(), amount });
        Ok(())
    }

    /// Pay the protocol fees accrued on one curve to the configured fee recipient. Anyone may call it.
    pub fn claim_protocol_fees(ctx: Context<ClaimProtocolFees>) -> Result<()> {
        let curve = &mut ctx.accounts.curve;
        let amount = curve.protocol_fees_owed;
        require!(amount > 0, FleaError::NothingToClaim);
        curve.protocol_fees_owed = 0;
        let curve_info = curve.to_account_info();
        let rent_floor = Rent::get()?.minimum_balance(curve_info.data_len());
        require!(curve_info.lamports().checked_sub(amount).ok_or(FleaError::Math)? >= rent_floor, FleaError::Insolvent);
        **curve_info.try_borrow_mut_lamports()? -= amount;
        **ctx.accounts.fee_recipient.to_account_info().try_borrow_mut_lamports()? += amount;
        emit!(ProtocolFeesClaimed { mint: curve.mint, recipient: ctx.accounts.fee_recipient.key(), amount });
        Ok(())
    }

    /// After the curve completes: hand the raised SOL and the tokens that were never for sale on the curve
    /// (the liquidity allocation) to the migration authority, which seeds the DEX pool. Trusted step.
    pub fn migrate(ctx: Context<Migrate>) -> Result<()> {
        let curve = &mut ctx.accounts.curve;
        require!(curve.complete, FleaError::CurveNotComplete);
        require!(!curve.migrated, FleaError::AlreadyMigrated);

        let sol = curve.real_sol;
        let tokens = ctx.accounts.vault.amount;
        curve.real_sol = 0;
        curve.migrated = true;

        let mint_key = curve.mint;
        let seeds: &[&[u8]] = &[b"curve", mint_key.as_ref(), &[curve.bump]];
        if tokens > 0 {
            token::transfer(
                CpiContext::new_with_signer(
                    ctx.accounts.token_program.to_account_info(),
                    Transfer { from: ctx.accounts.vault.to_account_info(), to: ctx.accounts.authority_tokens.to_account_info(), authority: curve.to_account_info() },
                    &[seeds],
                ),
                tokens,
            )?;
        }
        let curve_info = curve.to_account_info();
        let rent_floor = Rent::get()?.minimum_balance(curve_info.data_len());
        // Creator fees not yet claimed must stay behind with the rent.
        let owed: u64 = curve.unsettled_creator_fees + curve.protocol_fees_owed + curve.payees.iter().map(|p| p.owed).sum::<u64>();
        require!(curve_info.lamports().checked_sub(sol).ok_or(FleaError::Math)? >= rent_floor.checked_add(owed).ok_or(FleaError::Math)?, FleaError::Insolvent);
        **curve_info.try_borrow_mut_lamports()? -= sol;
        **ctx.accounts.migration_authority.to_account_info().try_borrow_mut_lamports()? += sol;
        emit!(Migrated { mint: curve.mint, sol, tokens });
        Ok(())
    }
}

// ---------------------------------------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------------------------------------

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy)]
pub struct ConfigParams {
    pub fee_recipient: Pubkey,
    pub migration_authority: Pubkey,
    pub protocol_fee_bps: u16,
    pub max_creator_fee_bps: u16,
    pub launch_fee: u64,
    pub virtual_sol: u64,
    pub virtual_tokens: u64,
    /// Tokens sold on the curve; the rest of the supply is the liquidity allocation.
    pub curve_tokens: u64,
}

impl ConfigParams {
    fn validate(&self) -> Result<()> {
        require!(self.fee_recipient != Pubkey::default() && self.migration_authority != Pubkey::default(), FleaError::BadConfig);
        require!(self.protocol_fee_bps <= MAX_PROTOCOL_FEE_BPS && self.max_creator_fee_bps <= MAX_CREATOR_FEE_BPS, FleaError::FeeTooHigh);
        require!(self.launch_fee <= MAX_LAUNCH_FEE, FleaError::FeeTooHigh);
        require!(self.virtual_sol >= MIN_VIRTUAL_SOL && self.curve_tokens > 0, FleaError::BadConfig);
        // Keep the end-of-curve price finite: some virtual tokens must always remain after the curve sells out.
        require!(self.virtual_tokens >= self.curve_tokens.saturating_add(TOTAL_SUPPLY / 100), FleaError::BadConfig);
        // The curve must be able to sell its whole allocation: strictly less than the virtual token reserve,
        // and no more than the supply that exists.
        require!(self.curve_tokens < self.virtual_tokens && self.curve_tokens <= TOTAL_SUPPLY, FleaError::BadConfig);
        Ok(())
    }
}

#[account]
#[derive(InitSpace)]
pub struct Config {
    pub admin: Pubkey,
    pub pending_admin: Pubkey,
    pub fee_recipient: Pubkey,
    pub migration_authority: Pubkey,
    pub protocol_fee_bps: u16,
    pub max_creator_fee_bps: u16,
    pub launch_fee: u64,
    pub virtual_sol: u64,
    pub virtual_tokens: u64,
    pub curve_tokens: u64,
    pub paused: bool,
    pub bump: u8,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Default, InitSpace)]
pub struct Payee {
    pub wallet: Pubkey,
    pub bps: u16,
    /// Settled and not yet paid out.
    pub owed: u64,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy)]
pub struct PayeeInput {
    pub wallet: Pubkey,
    pub bps: u16,
}

#[account]
#[derive(InitSpace)]
pub struct Curve {
    pub mint: Pubkey,
    pub creator: Pubkey,
    pub virtual_sol: u64,
    pub virtual_tokens: u64,
    pub real_sol: u64,
    pub real_tokens: u64,
    pub protocol_fee_bps: u16,
    pub creator_fee_bps: u16,
    /// Creator fees accrued since the last settlement (not yet credited to payees).
    pub unsettled_creator_fees: u64,
    /// Protocol fees accrued and not yet pulled to the fee recipient.
    pub protocol_fees_owed: u64,
    /// The wallet allowed to migrate THIS curve, fixed at launch. A later config change cannot redirect it.
    pub migration_authority: Pubkey,
    pub complete: bool,
    pub migrated: bool,
    pub payees: [Payee; MAX_PAYEES],
    pub payee_count: u8,
    pub created_at: i64,
    pub bump: u8,
}

impl Curve {
    fn reserves(&self) -> Reserves {
        Reserves { virtual_sol: self.virtual_sol, virtual_tokens: self.virtual_tokens, real_tokens: self.real_tokens, real_sol: self.real_sol }
    }
    fn set_reserves(&mut self, r: &Reserves) {
        self.virtual_sol = r.virtual_sol;
        self.virtual_tokens = r.virtual_tokens;
        self.real_tokens = r.real_tokens;
        self.real_sol = r.real_sol;
    }
}

// ---------------------------------------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------------------------------------

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    /// The program's own keypair must sign: proof the caller is the deployer.
    #[account(address = crate::ID @ FleaError::NotDeployer)]
    pub program_signer: Signer<'info>,
    #[account(init, payer = admin, space = 8 + Config::INIT_SPACE, seeds = [b"config"], bump)]
    pub config: Account<'info, Config>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct AdminOnly<'info> {
    pub admin: Signer<'info>,
    #[account(mut, seeds = [b"config"], bump = config.bump, has_one = admin @ FleaError::NotAdmin)]
    pub config: Account<'info, Config>,
}

#[derive(Accounts)]
pub struct AcceptAdmin<'info> {
    pub new_admin: Signer<'info>,
    #[account(mut, seeds = [b"config"], bump = config.bump)]
    pub config: Account<'info, Config>,
}

#[derive(Accounts)]
pub struct Create<'info> {
    #[account(mut)]
    pub creator: Signer<'info>,
    #[account(seeds = [b"config"], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut)]
    pub mint: Account<'info, Mint>,
    #[account(init, payer = creator, space = 8 + Curve::INIT_SPACE, seeds = [b"curve", mint.key().as_ref()], bump)]
    pub curve: Account<'info, Curve>,
    // init_if_needed: anyone can create this token account ahead of time, and a plain `init` would then fail
    // forever, letting a stranger block a launch for a few cents. It is safe to accept an existing one because
    // its address pins the mint and owner and the mint's supply is zero, so it is necessarily empty.
    #[account(init_if_needed, payer = creator, associated_token::mint = mint, associated_token::authority = curve)]
    pub vault: Account<'info, TokenAccount>,
    /// CHECK: only receives lamports; pinned to the configured recipient.
    #[account(mut, address = config.fee_recipient @ FleaError::BadFeeRecipient)]
    pub fee_recipient: UncheckedAccount<'info>,
    pub token_program: Program<'info, Token>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct Trade<'info> {
    #[account(mut)]
    pub user: Signer<'info>,
    #[account(seeds = [b"config"], bump = config.bump)]
    pub config: Account<'info, Config>,
    pub mint: Account<'info, Mint>,
    #[account(mut, seeds = [b"curve", mint.key().as_ref()], bump = curve.bump, has_one = mint)]
    pub curve: Account<'info, Curve>,
    #[account(mut, associated_token::mint = mint, associated_token::authority = curve)]
    pub vault: Account<'info, TokenAccount>,
    #[account(init_if_needed, payer = user, associated_token::mint = mint, associated_token::authority = user)]
    pub user_tokens: Account<'info, TokenAccount>,
    pub token_program: Program<'info, Token>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct ClaimCreatorFees<'info> {
    pub mint: Account<'info, Mint>,
    #[account(mut, seeds = [b"curve", mint.key().as_ref()], bump = curve.bump, has_one = mint)]
    pub curve: Account<'info, Curve>,
    /// CHECK: only receives lamports; checked against the payee table in the handler.
    #[account(mut)]
    pub payee: UncheckedAccount<'info>,
}

#[derive(Accounts)]
pub struct ClaimProtocolFees<'info> {
    #[account(seeds = [b"config"], bump = config.bump)]
    pub config: Account<'info, Config>,
    pub mint: Account<'info, Mint>,
    #[account(mut, seeds = [b"curve", mint.key().as_ref()], bump = curve.bump, has_one = mint)]
    pub curve: Account<'info, Curve>,
    /// CHECK: only receives lamports; pinned to the configured recipient.
    #[account(mut, address = config.fee_recipient @ FleaError::BadFeeRecipient)]
    pub fee_recipient: UncheckedAccount<'info>,
}

#[derive(Accounts)]
pub struct Migrate<'info> {
    #[account(mut)]
    pub migration_authority: Signer<'info>,
    pub mint: Account<'info, Mint>,
    #[account(mut, seeds = [b"curve", mint.key().as_ref()], bump = curve.bump, has_one = mint, has_one = migration_authority @ FleaError::NotMigrationAuthority)]
    pub curve: Account<'info, Curve>,
    #[account(mut, associated_token::mint = mint, associated_token::authority = curve)]
    pub vault: Account<'info, TokenAccount>,
    #[account(init_if_needed, payer = migration_authority, associated_token::mint = mint, associated_token::authority = migration_authority)]
    pub authority_tokens: Account<'info, TokenAccount>,
    pub token_program: Program<'info, Token>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

// ---------------------------------------------------------------------------------------------------------
// Events and errors
// ---------------------------------------------------------------------------------------------------------

#[event]
pub struct Launched {
    pub mint: Pubkey,
    pub creator: Pubkey,
    pub creator_fee_bps: u16,
    pub payee_count: u8,
    pub virtual_sol: u64,
    pub virtual_tokens: u64,
    pub curve_tokens: u64,
}

#[event]
pub struct Traded {
    pub mint: Pubkey,
    pub user: Pubkey,
    pub is_buy: bool,
    pub sol: u64,
    pub tokens: u64,
    pub protocol_fee: u64,
    pub creator_fee: u64,
    pub virtual_sol: u64,
    pub virtual_tokens: u64,
    pub real_sol: u64,
    pub real_tokens: u64,
}

#[event]
pub struct Completed {
    pub mint: Pubkey,
    pub real_sol: u64,
}

#[event]
pub struct Migrated {
    pub mint: Pubkey,
    pub sol: u64,
    pub tokens: u64,
}

#[event]
pub struct ProtocolFeesClaimed {
    pub mint: Pubkey,
    pub recipient: Pubkey,
    pub amount: u64,
}

#[event]
pub struct CreatorFeesClaimed {
    pub mint: Pubkey,
    pub payee: Pubkey,
    pub amount: u64,
}

#[error_code]
pub enum FleaError {
    #[msg("Launches and buys are paused")]
    Paused,
    #[msg("Fee is above the allowed maximum")]
    FeeTooHigh,
    #[msg("Invalid configuration")]
    BadConfig,
    #[msg("Mint must have 6 decimals, zero supply, no freeze authority, and the creator as mint authority")]
    BadMint,
    #[msg("Payees must be unique, at most five, and their shares must add up to 100%")]
    BadPayees,
    #[msg("Amount is zero, too small, or more than the curve can settle")]
    BadAmount,
    #[msg("Price moved beyond the slippage limit")]
    Slippage,
    #[msg("The curve is complete; trading has moved to the pool")]
    CurveComplete,
    #[msg("The curve is not complete yet")]
    CurveNotComplete,
    #[msg("Already migrated")]
    AlreadyMigrated,
    #[msg("Nothing to claim")]
    NothingToClaim,
    #[msg("Arithmetic overflow")]
    Math,
    #[msg("The curve account would fall below what it owes")]
    Insolvent,
    #[msg("Not the admin")]
    NotAdmin,
    #[msg("Not the pending admin")]
    NotPendingAdmin,
    #[msg("Not the migration authority")]
    NotMigrationAuthority,
    #[msg("Wrong fee recipient account")]
    BadFeeRecipient,
    #[msg("Initialize must be signed by the program keypair")]
    NotDeployer,
    #[msg("The launch fee is higher than the caller accepted")]
    LaunchFeeChanged,
}
