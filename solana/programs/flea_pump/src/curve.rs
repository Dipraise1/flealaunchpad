//! Bonding-curve arithmetic, kept free of Solana types so it can be unit-tested on the host.
//!
//! The curve is constant-product over *virtual* reserves, the same shape pump.fun uses: a launch starts with
//! `virtual_sol` lamports and `virtual_tokens` base units on the books although no SOL has been paid in. Every
//! buy adds its net SOL and removes the tokens it bought; every sell does the reverse. Only `real_tokens` of the
//! virtual token reserve can actually be sold on the curve; when they are gone the curve is complete.
//!
//! All rounding goes against the trader, so the curve can never owe more than it holds.

pub const BPS: u64 = 10_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Reserves {
    pub virtual_sol: u64,
    pub virtual_tokens: u64,
    /// Tokens still for sale on the curve.
    pub real_tokens: u64,
    /// SOL paid in by buyers, net of fees, and not yet paid back out to sellers.
    pub real_sol: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BuyQuote {
    /// Lamports actually charged to the buyer (can be less than offered when the curve sells out).
    pub gross: u64,
    pub protocol_fee: u64,
    pub creator_fee: u64,
    /// Lamports that enter the curve reserve.
    pub net: u64,
    pub tokens_out: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SellQuote {
    /// Lamports leaving the curve reserve.
    pub gross: u64,
    pub protocol_fee: u64,
    pub creator_fee: u64,
    /// Lamports paid to the seller.
    pub net: u64,
}

fn mul_div_floor(a: u64, b: u64, c: u64) -> Option<u64> {
    if c == 0 {
        return None;
    }
    u64::try_from((a as u128).checked_mul(b as u128)? / c as u128).ok()
}

fn mul_div_ceil(a: u64, b: u64, c: u64) -> Option<u64> {
    if c == 0 {
        return None;
    }
    let n = (a as u128).checked_mul(b as u128)?;
    u64::try_from(n.div_ceil(c as u128)).ok()
}

/// Fees on `gross`: the protocol's share and the creator's, each rounded down.
fn fees(gross: u64, protocol_bps: u16, creator_bps: u16) -> Option<(u64, u64)> {
    Some((mul_div_floor(gross, protocol_bps as u64, BPS)?, mul_div_floor(gross, creator_bps as u64, BPS)?))
}

/// Quote a buy of `sol_in` lamports. A buy that would take more than the curve has left is filled up to what is
/// left and charged only for that. Returns `None` on overflow or when nothing can be bought.
pub fn quote_buy(r: &Reserves, sol_in: u64, protocol_bps: u16, creator_bps: u16) -> Option<BuyQuote> {
    if sol_in == 0 || r.real_tokens == 0 {
        return None;
    }
    let fee_bps = protocol_bps as u64 + creator_bps as u64;
    if fee_bps >= BPS {
        return None;
    }
    let (protocol_fee, creator_fee) = fees(sol_in, protocol_bps, creator_bps)?;
    let net = sol_in.checked_sub(protocol_fee)?.checked_sub(creator_fee)?;
    // tokens_out = virtual_tokens * net / (virtual_sol + net), rounded down.
    let tokens_out = mul_div_floor(r.virtual_tokens, net, r.virtual_sol.checked_add(net)?)?;
    if tokens_out <= r.real_tokens {
        if tokens_out == 0 {
            return None;
        }
        return Some(BuyQuote { gross: sol_in, protocol_fee, creator_fee, net, tokens_out });
    }

    // Sell-out: price exactly the remaining tokens, rounding the SOL owed up.
    let tokens_out = r.real_tokens;
    let net = mul_div_ceil(r.virtual_sol, tokens_out, r.virtual_tokens.checked_sub(tokens_out)?)?;
    // Gross such that gross minus its fees covers `net`, rounded up, never above what was offered.
    let gross = mul_div_ceil(net, BPS, BPS - fee_bps)?.min(sol_in);
    let (protocol_fee, creator_fee) = fees(gross, protocol_bps, creator_bps)?;
    let net_after = gross.checked_sub(protocol_fee)?.checked_sub(creator_fee)?;
    if net_after < net {
        // Rounding left the reserve a lamport or two short of the exact price; the buyer offered too little.
        return None;
    }
    Some(BuyQuote { gross, protocol_fee, creator_fee, net: net_after, tokens_out })
}

/// Quote a sell of `tokens_in` base units. Returns `None` on overflow or when the curve cannot pay.
pub fn quote_sell(r: &Reserves, tokens_in: u64, protocol_bps: u16, creator_bps: u16) -> Option<SellQuote> {
    if tokens_in == 0 {
        return None;
    }
    // sol_out = virtual_sol * tokens_in / (virtual_tokens + tokens_in), rounded down.
    let gross = mul_div_floor(r.virtual_sol, tokens_in, r.virtual_tokens.checked_add(tokens_in)?)?;
    if gross == 0 || gross > r.real_sol {
        return None;
    }
    let (protocol_fee, creator_fee) = fees(gross, protocol_bps, creator_bps)?;
    let net = gross.checked_sub(protocol_fee)?.checked_sub(creator_fee)?;
    Some(SellQuote { gross, protocol_fee, creator_fee, net })
}

pub fn apply_buy(r: &mut Reserves, q: &BuyQuote) -> Option<()> {
    r.virtual_sol = r.virtual_sol.checked_add(q.net)?;
    r.virtual_tokens = r.virtual_tokens.checked_sub(q.tokens_out)?;
    r.real_sol = r.real_sol.checked_add(q.net)?;
    r.real_tokens = r.real_tokens.checked_sub(q.tokens_out)?;
    Some(())
}

pub fn apply_sell(r: &mut Reserves, tokens_in: u64, q: &SellQuote) -> Option<()> {
    r.virtual_sol = r.virtual_sol.checked_sub(q.gross)?;
    r.virtual_tokens = r.virtual_tokens.checked_add(tokens_in)?;
    r.real_sol = r.real_sol.checked_sub(q.gross)?;
    r.real_tokens = r.real_tokens.checked_add(tokens_in)?;
    Some(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const SOL: u64 = 1_000_000_000;
    const TOKEN: u64 = 1_000_000;

    fn fresh() -> Reserves {
        Reserves { virtual_sol: 30 * SOL, virtual_tokens: 1_073_000_000 * TOKEN, real_tokens: 793_100_000 * TOKEN, real_sol: 0 }
    }

    #[test]
    fn first_buy_matches_the_formula() {
        let r = fresh();
        let q = quote_buy(&r, SOL, 100, 100).unwrap();
        assert_eq!(q.protocol_fee, SOL / 100);
        assert_eq!(q.creator_fee, SOL / 100);
        assert_eq!(q.net, SOL - 2 * (SOL / 100));
        let expect = (r.virtual_tokens as u128 * q.net as u128 / (r.virtual_sol + q.net) as u128) as u64;
        assert_eq!(q.tokens_out, expect);
        assert_eq!(q.gross, SOL);
    }

    #[test]
    fn buy_then_sell_never_profits() {
        for sol in [1u64, 1_000, SOL / 10, SOL, 10 * SOL, 40 * SOL] {
            for (p, c) in [(0u16, 0u16), (100, 0), (100, 100), (200, 300)] {
                let mut r = fresh();
                let Some(b) = quote_buy(&r, sol, p, c) else { continue };
                apply_buy(&mut r, &b).unwrap();
                // A dust buy (a few lamports) buys tokens worth less than one lamport back; that sell is refused.
                let Some(s) = quote_sell(&r, b.tokens_out, p, c) else {
                    assert!(sol <= 1_000, "only dust-sized positions may be unsellable, got {sol}");
                    continue;
                };
                assert!(s.net <= b.gross, "round trip must not profit: in {} out {}", b.gross, s.net);
                assert!(s.gross <= b.net, "the reserve never pays out more than it took in");
                apply_sell(&mut r, b.tokens_out, &s).unwrap();
                assert!(r.real_sol <= SOL, "at most dust is left behind");
                assert_eq!(r.real_tokens, fresh().real_tokens);
            }
        }
    }

    #[test]
    fn oversized_buy_sells_out_and_charges_only_for_what_it_got() {
        let mut r = fresh();
        let q = quote_buy(&r, 1_000 * SOL, 100, 100).unwrap();
        assert_eq!(q.tokens_out, r.real_tokens);
        assert!(q.gross < 1_000 * SOL);
        // The classic pump.fun numbers: ~85 SOL fills the curve.
        assert!(q.net > 84 * SOL && q.net < 86 * SOL, "net to fill was {}", q.net);
        apply_buy(&mut r, &q).unwrap();
        assert_eq!(r.real_tokens, 0);
        assert!(quote_buy(&r, SOL, 100, 100).is_none(), "a complete curve sells nothing");
    }

    #[test]
    fn many_small_buys_fill_the_curve_and_the_reserve_always_covers_sells() {
        let mut r = fresh();
        let mut paid_in = 0u128;
        let mut bought = 0u64;
        let mut i = 0u64;
        while r.real_tokens > 0 {
            let amount = SOL / 2 + (i * 7_919) % SOL;
            let q = quote_buy(&r, amount, 100, 50).unwrap();
            apply_buy(&mut r, &q).unwrap();
            paid_in += q.net as u128;
            bought += q.tokens_out;
            i += 1;
            assert!(i < 10_000);
        }
        assert_eq!(bought, fresh().real_tokens);
        assert_eq!(r.real_sol as u128, paid_in);
        // Selling everything back can never ask the reserve for more than it holds.
        let s = quote_sell(&r, bought, 100, 50).unwrap();
        assert!(s.gross <= r.real_sol);
    }

    #[test]
    fn sell_cannot_drain_more_than_the_reserve() {
        let mut r = fresh();
        let b = quote_buy(&r, SOL, 0, 0).unwrap();
        apply_buy(&mut r, &b).unwrap();
        // Tokens that were never bought from this curve cannot be sold for SOL it does not hold.
        assert!(quote_sell(&r, b.tokens_out * 3, 0, 0).is_none());
    }

    #[test]
    fn rejects_zero_and_absurd_fees() {
        let r = fresh();
        assert!(quote_buy(&r, 0, 100, 100).is_none());
        assert!(quote_sell(&r, 0, 100, 100).is_none());
        assert!(quote_buy(&r, SOL, 6_000, 4_000).is_none());
    }
}
