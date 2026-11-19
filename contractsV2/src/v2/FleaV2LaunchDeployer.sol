// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FleaV2LauncherToken} from "./FleaV2LauncherToken.sol";
import {FleaV2BondingCurve} from "./FleaV2BondingCurve.sol";
import {FleaV2BuybackVault} from "./FleaV2BuybackVault.sol";
import {FeePolicySnapshot, IFleaV2FeeEscrow, IFleaV2FeePolicy} from "./interfaces/ILaunchpadV2.sol";

/**
 * @notice Every input FleaV2LaunchFactory hands the deployer to stand up one
 * launch. Grouped into a single calldata struct rather than a flat parameter
 * list so the deployer stays inside the EVM's 16-slot stack window when
 * compiled without the IR pipeline, which is the mode `forge coverage` uses.
 */
struct LaunchDeployment {
    address pairToken;
    address creatorFeeRecipient;
    address originalDeployer;
    IFleaV2FeePolicy feePolicy;
    FeePolicySnapshot policy;
    IFleaV2FeeEscrow feeEscrow;
    FleaV2BuybackVault buybackVault;
    uint256 phantomQuote;
    uint256 curveFeeBps;
    uint256 creatorTaxBps;
    bool buybackEnabled;
    uint256 graduationThreshold;
    uint256 snipeTaxStartBps;
    uint256 snipeTaxSeconds;
    bool buybackBurn;
    uint256 supply;
    // CREATE2 salt, namespaced per originalDeployer before use.
    bytes32 salt;
    string name;
    string symbol;
    string logo;
    string description;
    FleaV2LauncherToken.Socials socials;
}

/**
 * @title FleaV2LaunchDeployer
 * @notice Deploys the bonding curve and launch token pair for one pons v2
 * launch on FleaV2LaunchFactory's behalf. Split out into its own contract
 * purely so FleaV2LaunchFactory's own bytecode stays under EIP-170's
 * 24576-byte deployed-code limit: embedding two full contracts' creation
 * code via `new` inside the factory itself was the single largest
 * contributor to its size. Both new contracts still record the real
 * factory's address explicitly (never this deployer's), since they gate
 * privileged calls on it.
 */
contract FleaV2LaunchDeployer {
    // Metadata is stored on the token and read back by unbounded-return view
    // functions, so an unbounded write here becomes a permanently unreadable
    // token: `socials()` returns all five strings at once and would run out
    // of gas or time out an RPC node. Bounding the write is the only place
    // the limit can be enforced, since the strings are immutable afterwards.
    uint256 private constant MAX_NAME_LENGTH = 64;
    uint256 private constant MAX_SYMBOL_LENGTH = 16;
    uint256 private constant MAX_LOGO_LENGTH = 512;
    uint256 private constant MAX_DESCRIPTION_LENGTH = 2048;
    uint256 private constant MAX_SOCIAL_LENGTH = 256;

    error NotFactory();
    error MetadataTooLong();

    address public immutable factory;

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    constructor(address factory_) {
        if (factory_ == address(0)) revert NotFactory();
        factory = factory_;
    }

    /**
     * @notice Deploys a fresh curve/token pair and returns both addresses.
     * Both contracts are told `factory` (not this deployer) is their
     * privileged caller. Wiring the curve to its token via `initialize()` is
     * left to the factory itself, since that call is `onlyFactory`-gated.
     */
    function deployLaunch(LaunchDeployment calldata params)
        external
        onlyFactory
        returns (address token, address curve)
    {
        _requireMetadataWithinLimits(params);

        bytes32 salt = _namespacedSalt(params);
        curve = address(
            new FleaV2BondingCurve{salt: salt}(
                params.pairToken,
                params.creatorFeeRecipient,
                factory,
                params.feePolicy,
                params.policy,
                params.feeEscrow,
                params.buybackVault,
                params.phantomQuote,
                params.curveFeeBps,
                params.creatorTaxBps,
                params.buybackEnabled,
                params.graduationThreshold,
                params.snipeTaxStartBps,
                params.snipeTaxSeconds,
                params.buybackBurn
            )
        );
        token = address(
            new FleaV2LauncherToken{salt: salt}(
                params.name,
                params.symbol,
                params.logo,
                params.description,
                params.socials,
                params.originalDeployer,
                curve,
                factory,
                params.supply
            )
        );
    }

    /**
     * @notice Predicts the curve and token addresses `deployLaunch` would
     * create for these exact parameters. Any change to a constructor
     * argument (fees, policy, metadata) changes both addresses.
     */
    function predictLaunchAddresses(LaunchDeployment calldata params)
        external
        view
        returns (address curve, address token)
    {
        bytes32 salt = _namespacedSalt(params);
        curve = _create2Address(salt, keccak256(_curveInitCode(params)));
        token = _create2Address(salt, keccak256(_tokenInitCode(params, curve)));
    }

    function _namespacedSalt(LaunchDeployment calldata params) private pure returns (bytes32) {
        return keccak256(abi.encode(params.originalDeployer, params.salt));
    }

    function _create2Address(bytes32 salt, bytes32 initCodeHash) private view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    function _curveInitCode(LaunchDeployment calldata params) private view returns (bytes memory) {
        return abi.encodePacked(
            type(FleaV2BondingCurve).creationCode,
            abi.encode(
                params.pairToken,
                params.creatorFeeRecipient,
                factory,
                params.feePolicy,
                params.policy,
                params.feeEscrow,
                params.buybackVault,
                params.phantomQuote,
                params.curveFeeBps,
                params.creatorTaxBps,
                params.buybackEnabled,
                params.graduationThreshold,
                params.snipeTaxStartBps,
                params.snipeTaxSeconds,
                params.buybackBurn
            )
        );
    }

    function _tokenInitCode(LaunchDeployment calldata params, address curve) private view returns (bytes memory) {
        return abi.encodePacked(
            type(FleaV2LauncherToken).creationCode,
            abi.encode(
                params.name,
                params.symbol,
                params.logo,
                params.description,
                params.socials,
                params.originalDeployer,
                curve,
                factory,
                params.supply
            )
        );
    }

    /**
     * @notice Reverts unless every metadata string fits its length cap.
     * @dev The factory already rejects an empty name or symbol, so only the
     * upper bound is checked here.
     */
    function _requireMetadataWithinLimits(LaunchDeployment calldata params) private pure {
        if (
            bytes(params.name).length > MAX_NAME_LENGTH || bytes(params.symbol).length > MAX_SYMBOL_LENGTH
                || bytes(params.logo).length > MAX_LOGO_LENGTH
                || bytes(params.description).length > MAX_DESCRIPTION_LENGTH
        ) {
            revert MetadataTooLong();
        }
        if (
            bytes(params.socials.twitter).length > MAX_SOCIAL_LENGTH
                || bytes(params.socials.telegram).length > MAX_SOCIAL_LENGTH
                || bytes(params.socials.discord).length > MAX_SOCIAL_LENGTH
                || bytes(params.socials.website).length > MAX_SOCIAL_LENGTH
                || bytes(params.socials.farcaster).length > MAX_SOCIAL_LENGTH
        ) {
            revert MetadataTooLong();
        }
    }
}
