/**
 * End-to-end run against the compiled program in bankrun (an in-process Solana runtime).
 * Every test checks where the lamports and tokens ended up, not only that the call succeeded.
 */
import * as anchor from "@coral-xyz/anchor";
import { BN, Program } from "@coral-xyz/anchor";
import { Keypair, LAMPORTS_PER_SOL, PublicKey, SystemProgram, Transaction } from "@solana/web3.js";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID, MINT_SIZE, TOKEN_PROGRAM_ID, createInitializeMint2Instruction, getAssociatedTokenAddressSync,
} from "@solana/spl-token";
import { BankrunProvider, startAnchor } from "anchor-bankrun";
import { assert } from "chai";
import { readFileSync } from "fs";
import { createAssociatedTokenAccountInstruction } from "@solana/spl-token";
import type { FleaPump } from "../target/types/flea_pump";
// eslint-disable-next-line @typescript-eslint/no-var-requires
const idl = require("../target/idl/flea_pump.json");

const SOL = LAMPORTS_PER_SOL;
const TOKEN = 1_000_000;
const TOTAL_SUPPLY = new BN(1_000_000_000).mul(new BN(TOKEN));
const CURVE_TOKENS = new BN(793_100_000).mul(new BN(TOKEN));
const VIRTUAL_TOKENS = new BN(1_073_000_000).mul(new BN(TOKEN));
const LAUNCH_FEE = 0.02 * SOL;

describe("flea_pump", () => {
  let provider: BankrunProvider;
  let program: Program<FleaPump>;
  let context: Awaited<ReturnType<typeof startAnchor>>;
  const admin = Keypair.generate();
  /** The program's own keypair: `initialize` must be co-signed by it, so only the deployer can set the config. */
  const programKeypair = Keypair.fromSecretKey(Uint8Array.from(JSON.parse(readFileSync("target/deploy/flea_pump-keypair.json", "utf8"))));
  const feeRecipient = Keypair.generate();
  const migrator = Keypair.generate();
  const creator = Keypair.generate();
  const artist = Keypair.generate();
  const alice = Keypair.generate();
  const bob = Keypair.generate();
  const [config] = PublicKey.findProgramAddressSync([Buffer.from("config")], new PublicKey(idl.address));

  const fund = (k: PublicKey, sol: number) => ({ address: k, info: { lamports: sol * SOL, data: Buffer.alloc(0), owner: SystemProgram.programId, executable: false } });
  const lamports = async (k: PublicKey) => Number((await context.banksClient.getAccount(k))?.lamports ?? 0);
  const tokenBalance = async (owner: PublicKey, mint: PublicKey, offCurve = false) => {
    const acc = await context.banksClient.getAccount(getAssociatedTokenAddressSync(mint, owner, offCurve));
    return acc ? new BN(Buffer.from(acc.data).subarray(64, 72), "le") : new BN(0);
  };
  const curveOf = (mint: PublicKey) => PublicKey.findProgramAddressSync([Buffer.from("curve"), mint.toBuffer()], program.programId)[0];
  const send = async (tx: Transaction, signers: Keypair[]) => provider.sendAndConfirm!(tx, signers);

  /** Create a bare mint the way the app will: 6 decimals, no freeze authority, creator as mint authority. */
  async function newMint(authority: Keypair, decimals = 6, freeze: PublicKey | null = null): Promise<Keypair> {
    const mint = Keypair.generate();
    const rent = await context.banksClient.getRent();
    const tx = new Transaction().add(
      SystemProgram.createAccount({ fromPubkey: authority.publicKey, newAccountPubkey: mint.publicKey, space: MINT_SIZE, lamports: Number(rent.minimumBalance(BigInt(MINT_SIZE))), programId: TOKEN_PROGRAM_ID }),
      createInitializeMint2Instruction(mint.publicKey, decimals, authority.publicKey, freeze),
    );
    await send(tx, [authority, mint]);
    return mint;
  }

  const tradeAccounts = (user: PublicKey, mint: PublicKey) => ({
    user, config, mint, curve: curveOf(mint),
    vault: getAssociatedTokenAddressSync(mint, curveOf(mint), true),
    userTokens: getAssociatedTokenAddressSync(mint, user),
    tokenProgram: TOKEN_PROGRAM_ID, associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID, systemProgram: SystemProgram.programId,
  });

  async function launch(by: Keypair, creatorFeeBps: number, payees: { wallet: PublicKey; bps: number }[]): Promise<PublicKey> {
    const mint = await newMint(by);
    await program.methods.create(creatorFeeBps, payees, new BN(LAUNCH_FEE)).accounts({
      creator: by.publicKey, config, mint: mint.publicKey, curve: curveOf(mint.publicKey),
      vault: getAssociatedTokenAddressSync(mint.publicKey, curveOf(mint.publicKey), true),
      feeRecipient: feeRecipient.publicKey,
      tokenProgram: TOKEN_PROGRAM_ID, associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID, systemProgram: SystemProgram.programId,
    } as never).signers([by]).rpc();
    return mint.publicKey;
  }

  const expectFail = async (p: Promise<unknown>, code: string) => {
    try { await p; } catch (e) { assert.include(String((e as Error).message ?? e) + JSON.stringify((e as { logs?: string[] }).logs ?? ""), code); return; }
    assert.fail(`expected failure ${code}`);
  };

  before(async () => {
    context = await startAnchor(".", [], [admin, feeRecipient, migrator, creator, artist, alice, bob].map((k) => fund(k.publicKey, 1_000)));
    provider = new BankrunProvider(context);
    anchor.setProvider(provider);
    program = new Program<FleaPump>(idl as never, provider);
    await program.methods.initialize({
      feeRecipient: feeRecipient.publicKey, migrationAuthority: migrator.publicKey,
      protocolFeeBps: 100, maxCreatorFeeBps: 300, launchFee: new BN(LAUNCH_FEE),
      virtualSol: new BN(30 * SOL), virtualTokens: VIRTUAL_TOKENS, curveTokens: CURVE_TOKENS,
    }).accounts({ admin: admin.publicKey, programSigner: programKeypair.publicKey, config, systemProgram: SystemProgram.programId } as never).signers([admin, programKeypair]).rpc();
  });

  it("initialize cannot be called by anyone but the deployer (it needs the program keypair's signature)", async () => {
    const stranger = Keypair.generate();
    await expectFail(program.methods.initialize({
      feeRecipient: alice.publicKey, migrationAuthority: alice.publicKey, protocolFeeBps: 100, maxCreatorFeeBps: 300, launchFee: new BN(0),
      virtualSol: new BN(30 * SOL), virtualTokens: VIRTUAL_TOKENS, curveTokens: CURVE_TOKENS,
    }).accounts({ admin: alice.publicKey, programSigner: stranger.publicKey, config, systemProgram: SystemProgram.programId } as never).signers([alice, stranger]).rpc(), "");
    // (Here the config already exists, so the runtime rejects the re-init before the signer check is reached.
    //  Either way a stranger cannot set or replace the config; the values set by the deployer are untouched.)
    const c = await program.account.config.fetch(config);
    assert.isTrue(c.admin.equals(admin.publicKey));
    assert.isTrue(c.feeRecipient.equals(feeRecipient.publicKey));
  });

  it("launch mints the whole supply into the vault, destroys the mint authority and charges the launch fee", async () => {
    const before = await lamports(feeRecipient.publicKey);
    const mint = await launch(creator, 100, []);
    assert.equal(await lamports(feeRecipient.publicKey) - before, LAUNCH_FEE);
    assert.isTrue((await tokenBalance(curveOf(mint), mint, true)).eq(TOTAL_SUPPLY));
    const mintAcc = await context.banksClient.getAccount(mint);
    assert.equal(Buffer.from(mintAcc!.data).readUInt32LE(0), 0, "mint authority option is None");
    const c = await program.account.curve.fetch(curveOf(mint));
    assert.isTrue(c.realTokens.eq(CURVE_TOKENS));
    assert.equal(c.payeeCount, 1);
    assert.isTrue(c.payees[0].wallet.equals(creator.publicKey));
  });

  it("refuses a mint with a freeze authority, wrong decimals, or existing supply", async () => {
    const frozen = await newMint(creator, 6, creator.publicKey);
    const accounts = (m: PublicKey) => ({
      creator: creator.publicKey, config, mint: m, curve: curveOf(m), vault: getAssociatedTokenAddressSync(m, curveOf(m), true), feeRecipient: feeRecipient.publicKey,
      tokenProgram: TOKEN_PROGRAM_ID, associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID, systemProgram: SystemProgram.programId,
    });
    await expectFail(program.methods.create(100, [], new BN(LAUNCH_FEE)).accounts(accounts(frozen.publicKey) as never).signers([creator]).rpc(), "BadMint");
    const nine = await newMint(creator, 9);
    await expectFail(program.methods.create(100, [], new BN(LAUNCH_FEE)).accounts(accounts(nine.publicKey) as never).signers([creator]).rpc(), "BadMint");
    const ok = await newMint(creator);
    await expectFail(program.methods.create(301, [], new BN(LAUNCH_FEE)).accounts(accounts(ok.publicKey) as never).signers([creator]).rpc(), "FeeTooHigh");
    await expectFail(program.methods.create(100, [{ wallet: creator.publicKey, bps: 6000 }, { wallet: artist.publicKey, bps: 3000 }], new BN(LAUNCH_FEE)).accounts(accounts(ok.publicKey) as never).signers([creator]).rpc(), "BadPayees");
    // A payee that could never be paid (the curve itself) is refused, and so is a launch fee above what the creator accepted.
    await expectFail(program.methods.create(100, [{ wallet: curveOf(ok.publicKey), bps: 5000 }, { wallet: creator.publicKey, bps: 5000 }], new BN(LAUNCH_FEE)).accounts(accounts(ok.publicKey) as never).signers([creator]).rpc(), "BadPayees");
    await expectFail(program.methods.create(100, [], new BN(LAUNCH_FEE - 1)).accounts(accounts(ok.publicKey) as never).signers([creator]).rpc(), "LaunchFeeChanged");
  });

  it("buy and sell move exactly the quoted amounts, and every lamport is accounted for", async () => {
    const mint = await launch(creator, 100, [{ wallet: creator.publicKey, bps: 7000 }, { wallet: artist.publicKey, bps: 3000 }]);
    const curve = curveOf(mint);
    const curveBefore = await lamports(curve);
    const feeBefore = await lamports(feeRecipient.publicKey);
    const aliceBefore = await lamports(alice.publicKey);

    await program.methods.buy(new BN(2 * SOL), new BN(1)).accounts(tradeAccounts(alice.publicKey, mint) as never).signers([alice]).rpc();
    let c = await program.account.curve.fetch(curve);
    const net = 2 * SOL - 0.02 * SOL - 0.02 * SOL;
    assert.equal(c.realSol.toNumber(), net);
    assert.equal(c.unsettledCreatorFees.toNumber(), 0.02 * SOL);
    assert.equal(c.protocolFeesOwed.toNumber(), 0.02 * SOL, "protocol fee accrues in the curve");
    assert.equal(await lamports(feeRecipient.publicKey) - feeBefore, 0, "no trade pays the fee recipient directly");
    assert.equal(await lamports(curve) - curveBefore, 2 * SOL, "the curve holds everything the buyer paid: reserve plus both fees");
    const bought = await tokenBalance(alice.publicKey, mint);
    const expected = VIRTUAL_TOKENS.mul(new BN(net)).div(new BN(30 * SOL + net));
    assert.isTrue(bought.eq(expected), "tokens out match the constant-product formula");
    assert.isTrue((await tokenBalance(curve, mint, true)).eq(TOTAL_SUPPLY.sub(bought)));
    // Alice paid the 2 SOL plus the rent for her token account and the transaction fee, nothing else.
    assert.isBelow(aliceBefore - (await lamports(alice.publicKey)) - 2 * SOL, 0.003 * SOL);

    // Slippage: asking for more tokens per SOL than the curve gives is refused.
    await expectFail(program.methods.buy(new BN(SOL), bought).accounts(tradeAccounts(bob.publicKey, mint) as never).signers([bob]).rpc(), "Slippage");

    const aliceMid = await lamports(alice.publicKey);
    await program.methods.sell(bought, new BN(1)).accounts(tradeAccounts(alice.publicKey, mint) as never).signers([alice]).rpc();
    c = await program.account.curve.fetch(curve);
    assert.isTrue((await tokenBalance(alice.publicKey, mint)).isZero());
    assert.isTrue(c.realTokens.eq(CURVE_TOKENS), "all tokens are back on the curve");
    assert.isAtMost(c.realSol.toNumber(), 10, "only rounding dust is left in the reserve");
    const got = (await lamports(alice.publicKey)) - aliceMid;
    assert.isBelow(got, net, "a round trip costs the fees; it can never profit");
    assert.isAbove(got, net * 0.97);
    // Curve lamports = rent + reserve dust + both kinds of fee from both trades.
    assert.equal(await lamports(curve) - curveBefore, c.realSol.toNumber() + c.unsettledCreatorFees.toNumber() + c.protocolFeesOwed.toNumber());

    // Anyone can push the protocol fees to the configured recipient; they can go nowhere else.
    const owed = c.protocolFeesOwed.toNumber();
    await expectFail(program.methods.claimProtocolFees().accounts({ config, mint, curve, feeRecipient: bob.publicKey } as never).rpc(), "BadFeeRecipient");
    await program.methods.claimProtocolFees().accounts({ config, mint, curve, feeRecipient: feeRecipient.publicKey } as never).rpc();
    assert.equal(await lamports(feeRecipient.publicKey) - feeBefore, owed);
    assert.equal((await program.account.curve.fetch(curve)).protocolFeesOwed.toNumber(), 0);
  });

  it("creator fees are split by the launch shares; anyone can trigger a payout but only the payee is paid", async () => {
    const mint = await launch(creator, 200, [{ wallet: creator.publicKey, bps: 7000 }, { wallet: artist.publicKey, bps: 3000 }]);
    const curve = curveOf(mint);
    await program.methods.buy(new BN(10 * SOL), new BN(1)).accounts(tradeAccounts(alice.publicKey, mint) as never).signers([alice]).rpc();
    const fees = 0.2 * SOL;
    const artistBefore = await lamports(artist.publicKey);
    const creatorBefore = await lamports(creator.publicKey);
    // Bob (a stranger) pays the transaction fee to trigger the artist's payout.
    await send(Object.assign(await program.methods.claimCreatorFees(1).accounts({ mint, curve, payee: artist.publicKey } as never).transaction(), { feePayer: bob.publicKey }), [bob]);
    assert.equal(await lamports(artist.publicKey) - artistBefore, fees * 0.3);
    // A wrong wallet for that slot is refused, and a second claim has nothing to pay.
    await expectFail(send(Object.assign(await program.methods.claimCreatorFees(0).accounts({ mint, curve, payee: bob.publicKey } as never).transaction(), { feePayer: bob.publicKey }), [bob]), "BadPayees");
    // (A different fee payer, so this is a new transaction rather than a replay of the first.)
    await expectFail(send(Object.assign(await program.methods.claimCreatorFees(1).accounts({ mint, curve, payee: artist.publicKey } as never).transaction(), { feePayer: alice.publicKey }), [alice]), "NothingToClaim");
    await send(Object.assign(await program.methods.claimCreatorFees(0).accounts({ mint, curve, payee: creator.publicKey } as never).transaction(), { feePayer: bob.publicKey }), [bob]);
    assert.equal(await lamports(creator.publicKey) - creatorBefore, fees * 0.7);
    const c = await program.account.curve.fetch(curve);
    assert.equal(c.unsettledCreatorFees.toNumber(), 0);
  });

  it("filling the curve completes it, stops trading, and only the migration authority can migrate", async () => {
    const mint = await launch(creator, 100, []);
    const curve = curveOf(mint);
    const bobBefore = await lamports(bob.publicKey);
    await program.methods.buy(new BN(500 * SOL), new BN(1)).accounts(tradeAccounts(bob.publicKey, mint) as never).signers([bob]).rpc();
    let c = await program.account.curve.fetch(curve);
    assert.isTrue(c.complete);
    assert.isTrue(c.realTokens.isZero());
    const spent = bobBefore - (await lamports(bob.publicKey));
    assert.isBelow(spent, 90 * SOL, "an oversized buy is charged only for what the curve had left (about 86.8 SOL with fees)");
    assert.isAbove(spent, 85 * SOL);
    assert.isTrue((await tokenBalance(bob.publicKey, mint)).eq(CURVE_TOKENS));

    await expectFail(program.methods.buy(new BN(SOL), new BN(1)).accounts(tradeAccounts(alice.publicKey, mint) as never).signers([alice]).rpc(), "CurveComplete");
    await expectFail(program.methods.sell(new BN(TOKEN), new BN(1)).accounts(tradeAccounts(bob.publicKey, mint) as never).signers([bob]).rpc(), "CurveComplete");

    const migrateAccounts = (who: PublicKey) => ({
      migrationAuthority: who, mint, curve, vault: getAssociatedTokenAddressSync(mint, curve, true), authorityTokens: getAssociatedTokenAddressSync(mint, who),
      tokenProgram: TOKEN_PROGRAM_ID, associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID, systemProgram: SystemProgram.programId,
    });
    await expectFail(program.methods.migrate().accounts(migrateAccounts(alice.publicKey) as never).signers([alice]).rpc(), "NotMigrationAuthority");

    const raised = c.realSol.toNumber();
    const owedToCreator = c.unsettledCreatorFees.toNumber();
    const owedToProtocol = c.protocolFeesOwed.toNumber();
    const migratorBefore = await lamports(migrator.publicKey);
    await program.methods.migrate().accounts(migrateAccounts(migrator.publicKey) as never).signers([migrator]).rpc();
    assert.isAbove((await lamports(migrator.publicKey)) - migratorBefore, raised - 0.01 * SOL, "the raised SOL goes to the migration authority");
    assert.isTrue((await tokenBalance(migrator.publicKey, mint)).eq(TOTAL_SUPPLY.sub(CURVE_TOKENS)), "with the liquidity allocation");
    c = await program.account.curve.fetch(curve);
    assert.isTrue(c.migrated);
    await expectFail(program.methods.migrate().accounts(migrateAccounts(migrator.publicKey) as never).signers([migrator]).rpc(), "AlreadyMigrated");

    // Migration must not take the creator's unclaimed fees with it.
    const creatorBefore = await lamports(creator.publicKey);
    await send(Object.assign(await program.methods.claimCreatorFees(0).accounts({ mint, curve, payee: creator.publicKey } as never).transaction(), { feePayer: bob.publicKey }), [bob]);
    assert.equal(await lamports(creator.publicKey) - creatorBefore, owedToCreator);
    const feeBefore = await lamports(feeRecipient.publicKey);
    await program.methods.claimProtocolFees().accounts({ config, mint, curve, feeRecipient: feeRecipient.publicKey } as never).rpc();
    assert.equal(await lamports(feeRecipient.publicKey) - feeBefore, owedToProtocol, "nor the protocol's");
  });

  it("nothing the admin sets can block a sell or redirect an existing curve's migration", async () => {
    const params = {
      feeRecipient: feeRecipient.publicKey, migrationAuthority: migrator.publicKey, protocolFeeBps: 100, maxCreatorFeeBps: 300, launchFee: new BN(LAUNCH_FEE),
      virtualSol: new BN(30 * SOL), virtualTokens: VIRTUAL_TOKENS, curveTokens: CURVE_TOKENS,
    };
    const mint = await launch(creator, 100, []);
    const curve = curveOf(mint);
    await program.methods.buy(new BN(SOL), new BN(1)).accounts(tradeAccounts(alice.publicKey, mint) as never).signers([alice]).rpc();
    // Admin points the fee recipient at an account that cannot receive lamports (the token program) and swaps
    // the migration wallet. Before the fix this froze every sell on every curve.
    await program.methods.updateConfig({ ...params, feeRecipient: TOKEN_PROGRAM_ID, migrationAuthority: alice.publicKey }, true).accounts({ admin: admin.publicKey, config } as never).signers([admin]).rpc();
    const held = await tokenBalance(alice.publicKey, mint);
    await program.methods.sell(held, new BN(1)).accounts(tradeAccounts(alice.publicKey, mint) as never).signers([alice]).rpc();
    assert.isTrue((await tokenBalance(alice.publicKey, mint)).isZero(), "the sell went through regardless");
    const c = await program.account.curve.fetch(curve);
    assert.isTrue(c.migrationAuthority.equals(migrator.publicKey), "the curve keeps the migration wallet it launched with");
    await program.methods.updateConfig(params, false).accounts({ admin: admin.publicKey, config } as never).signers([admin]).rpc();
  });

  it("a stranger pre-creating the vault token account cannot block a launch", async () => {
    const mint = await newMint(creator);
    const curve = curveOf(mint.publicKey);
    const vault = getAssociatedTokenAddressSync(mint.publicKey, curve, true);
    await send(new Transaction().add(createAssociatedTokenAccountInstruction(bob.publicKey, vault, curve, mint.publicKey)), [bob]);
    await program.methods.create(100, [], new BN(LAUNCH_FEE)).accounts({
      creator: creator.publicKey, config, mint: mint.publicKey, curve, vault, feeRecipient: feeRecipient.publicKey,
      tokenProgram: TOKEN_PROGRAM_ID, associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID, systemProgram: SystemProgram.programId,
    } as never).signers([creator]).rpc();
    assert.isTrue((await tokenBalance(curve, mint.publicKey, true)).eq(TOTAL_SUPPLY));
  });

  it("only the admin changes config, fee caps hold, and a pause stops buys but never sells", async () => {
    const params = {
      feeRecipient: feeRecipient.publicKey, migrationAuthority: migrator.publicKey, protocolFeeBps: 100, maxCreatorFeeBps: 300, launchFee: new BN(LAUNCH_FEE),
      virtualSol: new BN(30 * SOL), virtualTokens: VIRTUAL_TOKENS, curveTokens: CURVE_TOKENS,
    };
    await expectFail(program.methods.updateConfig(params, true).accounts({ admin: alice.publicKey, config } as never).signers([alice]).rpc(), "NotAdmin");
    await expectFail(program.methods.updateConfig({ ...params, protocolFeeBps: 201 }, false).accounts({ admin: admin.publicKey, config } as never).signers([admin]).rpc(), "FeeTooHigh");

    const mint = await launch(creator, 100, []);
    await program.methods.buy(new BN(SOL), new BN(1)).accounts(tradeAccounts(alice.publicKey, mint) as never).signers([alice]).rpc();
    await program.methods.updateConfig(params, true).accounts({ admin: admin.publicKey, config } as never).signers([admin]).rpc();
    await expectFail(program.methods.buy(new BN(SOL), new BN(1)).accounts(tradeAccounts(bob.publicKey, mint) as never).signers([bob]).rpc(), "Paused");
    const held = await tokenBalance(alice.publicKey, mint);
    await program.methods.sell(held, new BN(1)).accounts(tradeAccounts(alice.publicKey, mint) as never).signers([alice]).rpc();
    assert.isTrue((await tokenBalance(alice.publicKey, mint)).isZero(), "holders can always exit while paused");
    await program.methods.updateConfig(params, false).accounts({ admin: admin.publicKey, config } as never).signers([admin]).rpc();
  });
});

describe("flea_pump setup guard (fresh program, no config yet)", () => {
  it("a stranger who calls initialize first is refused; only the holder of the program keypair can set the config", async () => {
    const stranger = Keypair.generate();
    const fake = Keypair.generate();
    const ctx = await startAnchor(".", [], [{ address: stranger.publicKey, info: { lamports: 10 * SOL, data: Buffer.alloc(0), owner: SystemProgram.programId, executable: false } }]);
    const provider = new BankrunProvider(ctx);
    const program = new Program<FleaPump>(idl as never, provider);
    const [config] = PublicKey.findProgramAddressSync([Buffer.from("config")], program.programId);
    const params = {
      feeRecipient: stranger.publicKey, migrationAuthority: stranger.publicKey, protocolFeeBps: 100, maxCreatorFeeBps: 300, launchFee: new BN(0),
      virtualSol: new BN(30 * SOL), virtualTokens: VIRTUAL_TOKENS, curveTokens: CURVE_TOKENS,
    };
    let message = "";
    try {
      await program.methods.initialize(params).accounts({ admin: stranger.publicKey, programSigner: fake.publicKey, config, systemProgram: SystemProgram.programId } as never).signers([stranger, fake]).rpc();
    } catch (e) { message = String((e as Error).message ?? e) + JSON.stringify((e as { logs?: string[] }).logs ?? ""); }
    assert.include(message, "NotDeployer");
    assert.isNull(await ctx.banksClient.getAccount(config), "no config was created");
  });
});
