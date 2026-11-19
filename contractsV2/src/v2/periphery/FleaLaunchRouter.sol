// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FleaV2LaunchFactory} from "../FleaV2LaunchFactory.sol";
import {FleaV2BondingCurve} from "../FleaV2BondingCurve.sol";
import {FleaV2CreatorSplitterFactory} from "./FleaV2CreatorSplitterFactory.sol";

/**
 * @title FleaLaunchRouter
 * @notice One transaction for what a creator otherwise does in three: create the fee split, launch the token,
 * and take the first buy. Because all three land together, nobody can buy between the launch and the creator's
 * own buy, and the split is in place before the first fee is ever charged.
 *
 * The router is the factory's `launchForwarder`. It holds no funds between calls and has no owner: it forwards
 * the caller's own launch, passes the real caller to the factory as the deployer, sends bought tokens straight
 * to the caller, and returns every wei it did not spend.
 *
 * Fee split: pass payees and shares and the router deploys a `FleaV2CreatorSplitter` (admin = the caller) and
 * makes it the launch's creator fee recipient. The split is fixed at creation. Anyone can later call
 * `sweepCurveFees` and `distribute` on the splitter to pay everyone out; no payee can be skipped.
 *
 * First buy: sent to the curve with the caller as recipient. The caller is exempt from the snipe tax up to the
 * curve's exempt allowance (10% of the graduation threshold). A larger first buy would be charged the launch-second
 * snipe tax, which is close to the whole amount, so the router refuses it instead of letting a creator lose it.
 *
 * FLÈA address prefix: with `requireFleaPrefix` the launch only goes through if the new token's address starts
 * with 0xf1ea ("flea" in hex). The address is fixed by `params.salt`, so the caller finds a salt that produces
 * one before sending (about 65,000 tries on average, done off-chain in a second or two). The prefix is branding,
 * not proof of origin: the same address can be reached by launching on the factory directly with the same salt.
 * The `RouterLaunch` event is the record that a token came through this router.
 *
 * Native-quote (ETH) launches only.
 */
contract FleaLaunchRouter is ReentrancyGuard {
    struct Split {
        address[] payees;
        uint256[] shares;
    }

    FleaV2LaunchFactory public immutable factory;
    FleaV2CreatorSplitterFactory public immutable splitterFactory;

    error ZeroAddress();
    error InsufficientValue(uint256 required, uint256 sent);
    error FirstBuyOverExemptAllowance(uint256 firstBuy, uint256 allowance);
    error RefundFailed();
    error TokenAddressNotFlea(address token);

    /// "flea" as the leading two bytes of an address: 0xf1ea….
    uint160 internal constant FLEA_PREFIX = 0xf1ea;

    event RouterLaunch(
        address indexed creator, address indexed token, address indexed curve, address splitter, uint256 firstBuy, uint256 tokensOut, bool fleaPrefix
    );

    constructor(FleaV2LaunchFactory factory_, FleaV2CreatorSplitterFactory splitterFactory_) {
        if (address(factory_) == address(0) || address(splitterFactory_) == address(0)) revert ZeroAddress();
        factory = factory_;
        splitterFactory = splitterFactory_;
    }

    /// True when `account` starts with 0xf1ea.
    function isFleaAddress(address account) public pure returns (bool) {
        return uint160(account) >> 144 == FLEA_PREFIX;
    }

    /// Curves refund the unspent part of a clamped buy to the router, which passes it on.
    receive() external payable {}

    /**
     * @param params      Launch terms. `creatorFeeRecipient` is replaced by the splitter when a split is given.
     * @param launchConfigId  Factory launch config (native-quote).
     * @param snipeTaxExemptions  Extra wallets the creator declares for the launch window (bounded by the factory).
     * @param split       Payees and shares for the creator's fees. Empty for no split.
     * @param firstBuy    Wei to spend on the curve in the same transaction. Zero for none.
     * @param minTokensOut  Slippage bound for the first buy.
     * @param requireFleaPrefix  Revert unless the token's address starts with 0xf1ea.
     * @dev `msg.value` must cover the launch fee plus `firstBuy`; anything above that is returned.
     */
    function launch(
        FleaV2LaunchFactory.TokenParams calldata params,
        uint256 launchConfigId,
        address[] calldata snipeTaxExemptions,
        Split calldata split,
        uint256 firstBuy,
        uint256 minTokensOut,
        bool requireFleaPrefix
    ) external payable nonReentrant returns (address token, address curve, address splitter, uint256 tokensOut) {
        uint256 fee = factory.launchFee();
        if (msg.value < fee + firstBuy) revert InsufficientValue(fee + firstBuy, msg.value);
        // Whatever sat here before this call (a mistaken or forced transfer) is not this caller's to collect.
        uint256 heldBefore = address(this).balance - msg.value;

        FleaV2LaunchFactory.TokenParams memory p = params;
        if (split.payees.length != 0) {
            // Salted per creator and per launch, so the same split can be reused across launches.
            bytes32 splitSalt = keccak256(abi.encode(msg.sender, params.salt));
            // The address commits to admin, payees and shares, so a splitter already at it is exactly the one
            // asked for. Reusing it stops anyone from pre-deploying the clone to make this launch revert.
            splitter = splitterFactory.predictSplitter(msg.sender, split.payees, split.shares, splitSalt);
            if (splitter.code.length == 0) {
                splitter = splitterFactory.createSplitter(msg.sender, split.payees, split.shares, splitSalt);
            }
            p.creatorFeeRecipient = splitter;
        }

        (token, curve) = factory.launchTokenFor{value: fee}(p, launchConfigId, address(0), msg.sender, snipeTaxExemptions);

        if (requireFleaPrefix && !isFleaAddress(token)) revert TokenAddressNotFlea(token);

        if (firstBuy != 0) {
            uint256 allowance = FleaV2BondingCurve(payable(curve)).exemptAllowance();
            if (firstBuy > allowance) revert FirstBuyOverExemptAllowance(firstBuy, allowance);
            tokensOut = FleaV2BondingCurve(payable(curve)).buy{value: firstBuy}(firstBuy, minTokensOut, msg.sender);
        }

        emit RouterLaunch(msg.sender, token, curve, splitter, firstBuy, tokensOut, isFleaAddress(token));

        uint256 left = address(this).balance - heldBefore;
        if (left != 0) {
            (bool ok,) = msg.sender.call{value: left}("");
            if (!ok) revert RefundFailed();
        }
    }
}
