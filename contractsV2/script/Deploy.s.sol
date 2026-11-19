// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {FleaV2LaunchFactory} from "../src/v2/FleaV2LaunchFactory.sol";
import {FleaV2LaunchDeployer} from "../src/v2/FleaV2LaunchDeployer.sol";
import {FleaV2GraduationExecutor} from "../src/v2/FleaV2GraduationExecutor.sol";
import {FleaV2LaunchLocker} from "../src/v2/FleaV2LaunchLocker.sol";
import {FleaV2BuybackVault} from "../src/v2/FleaV2BuybackVault.sol";
import {FleaV2FeeEscrow} from "../src/v2/FleaV2FeeEscrow.sol";
import {FleaV2MemeHook} from "../src/v2/hooks/FleaV2MemeHook.sol";
import {FleaV2CreatorSplitterFactory} from "../src/v2/periphery/FleaV2CreatorSplitterFactory.sol";
import {FleaLaunchRouter} from "../src/v2/periphery/FleaLaunchRouter.sol";
import {IFleaV2FeeEscrow} from "../src/v2/interfaces/ILaunchpadV2.sol";

/**
 * Deploys the whole launchpad and wires it, in the same order the graduation tests use.
 *
 * Defaults target Robinhood Chain (4663) and its Uniswap V4 deployment. Everything is overridable by env:
 *
 *   PROTOCOL_FEE_RECIPIENT  required. Receives the protocol's share of trade fees and the launch fee.
 *   OWNER                   final owner of factory / hook / vault / locker. Default: the deployer.
 *                           If different, ownership is OFFERED (Ownable2Step); OWNER must call acceptOwnership() on all four.
 *   LAUNCH_FEE              wei charged per launch. Default 0.0005 ether.
 *   LAUNCH_ENABLED          "true" opens launches in this run. Default false: deploy closed, open deliberately.
 *   POOL_MANAGER / POSITION_MANAGER / PERMIT2   Uniswap V4 addresses. Defaults: Robinhood Chain.
 *   PHANTOM_QUOTE / GRADUATION_THRESHOLD / CURVE_FEE_BPS   launch config 0. Defaults mirror the live Pons config.
 *
 * Dry run (no transactions):  forge script script/Deploy.s.sol --rpc-url $RPC --sender <deployer>
 * Real deploy:                forge script script/Deploy.s.sol --rpc-url $RPC --account <keystore> --broadcast
 */
contract Deploy is Script {
    /// Arachnid deterministic deployer, present on Robinhood Chain. Needed so the hook lands on an address whose
    /// low bits spell its Uniswap V4 permissions.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 internal constant HOOK_FLAGS =
        uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);

    // Robinhood Chain (4663), read from the live Pons factory on 2026-11-18.
    address internal constant RH_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant RH_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    struct Deployed {
        FleaV2FeeEscrow escrow;
        FleaV2MemeHook hook;
        FleaV2BuybackVault vault;
        FleaV2LaunchLocker locker;
        FleaV2LaunchFactory factory;
        FleaV2LaunchDeployer launchDeployer;
        FleaV2GraduationExecutor executor;
        FleaV2CreatorSplitterFactory splitterFactory;
        FleaLaunchRouter router;
        address owner;
        bool ownershipPending;
    }

    function run() external returns (Deployed memory d) {
        address deployer = msg.sender;
        address protocol = vm.envAddress("PROTOCOL_FEE_RECIPIENT");
        address owner = vm.envOr("OWNER", deployer);
        address manager = vm.envOr("POOL_MANAGER", RH_POOL_MANAGER);
        address posm = vm.envOr("POSITION_MANAGER", RH_POSITION_MANAGER);
        address permit2 = vm.envOr("PERMIT2", PERMIT2);
        require(protocol != address(0) && owner != address(0), "zero recipient/owner");
        require(manager.code.length > 0 && posm.code.length > 0 && permit2.code.length > 0, "Uniswap V4 not at these addresses");
        require(CREATE2_DEPLOYER.code.length > 0, "CREATE2 deployer missing on this chain");

        vm.startBroadcast(deployer);

        d.escrow = new FleaV2FeeEscrow();

        // The deployer owns everything while wiring; ownership moves at the end.
        bytes memory hookInit =
            abi.encodePacked(type(FleaV2MemeHook).creationCode, abi.encode(manager, address(d.escrow), protocol, deployer));
        (address hookAddr, bytes32 salt) = _mineHook(keccak256(hookInit));
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, hookInit));
        require(ok && hookAddr.code.length > 0, "hook deploy failed");
        d.hook = FleaV2MemeHook(payable(hookAddr));

        d.vault = new FleaV2BuybackVault(deployer, d.hook, IFleaV2FeeEscrow(address(d.escrow)));
        d.locker = new FleaV2LaunchLocker(deployer, posm);
        d.factory = new FleaV2LaunchFactory(
            deployer,
            IPoolManager(manager),
            IPositionManager(posm),
            IAllowanceTransfer(permit2),
            d.locker,
            d.hook,
            IFleaV2FeeEscrow(address(d.escrow)),
            d.vault,
            vm.envOr("LAUNCH_FEE", uint256(0.0005 ether))
        );
        d.launchDeployer = new FleaV2LaunchDeployer(address(d.factory));
        d.executor =
            new FleaV2GraduationExecutor(IPositionManager(posm), IAllowanceTransfer(permit2), d.locker, address(d.factory));
        d.factory.setLaunchDeployer(d.launchDeployer);
        d.factory.setGraduationExecutor(d.executor);
        d.hook.setFactory(address(d.factory));
        d.hook.setBuybackVault(d.vault);
        d.vault.setFactory(address(d.factory));
        d.locker.setFactory(address(d.factory));

        // Launch config 0: native ETH quote, mirroring the live Pons economics.
        d.factory.addLaunchConfig(
            FleaV2LaunchFactory.LaunchConfig({
                supply: 1_000_000_000 ether,
                curveFeeBps: vm.envOr("CURVE_FEE_BPS", uint256(100)),
                phantomQuote: vm.envOr("PHANTOM_QUOTE", uint256(1.68 ether)),
                graduationThreshold: vm.envOr("GRADUATION_THRESHOLD", uint256(4.2 ether)),
                poolFee: 0,
                tickSpacing: 200,
                enabled: true
            })
        );
        if (vm.envOr("LAUNCH_ENABLED", false)) d.factory.setLaunchEnabled(true);

        d.splitterFactory = new FleaV2CreatorSplitterFactory(IFleaV2FeeEscrow(address(d.escrow)));
        // One-transaction launch + fee split + first buy. It is the factory's trusted forwarder.
        d.router = new FleaLaunchRouter(d.factory, d.splitterFactory);
        d.factory.setLaunchForwarder(address(d.router));

        d.owner = owner;
        if (owner != deployer) {
            d.factory.transferOwnership(owner);
            d.hook.transferOwnership(owner);
            d.vault.transferOwnership(owner);
            d.locker.transferOwnership(owner);
            d.ownershipPending = true;
        }
        vm.stopBroadcast();

        _report(d, manager, posm, permit2, protocol);
    }

    /// First salt whose CREATE2 address carries exactly the hook's permission bits.
    function _mineHook(bytes32 initCodeHash) internal pure returns (address hookAddr, bytes32 salt) {
        for (uint256 i = 0; i < 500_000; i++) {
            salt = bytes32(i);
            hookAddr = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, initCodeHash)))));
            if (uint160(hookAddr) & ALL_HOOK_MASK == HOOK_FLAGS) return (hookAddr, salt);
        }
        revert("no hook salt found");
    }

    function _report(Deployed memory d, address manager, address posm, address permit2, address protocol) internal {
        console2.log("chain", block.chainid);
        console2.log("factory          ", address(d.factory));
        console2.log("launchDeployer   ", address(d.launchDeployer));
        console2.log("graduationExec   ", address(d.executor));
        console2.log("graduationGuard  ", address(d.factory.graduationGuard()));
        console2.log("memeHook         ", address(d.hook));
        console2.log("feeEscrow        ", address(d.escrow));
        console2.log("buybackVault     ", address(d.vault));
        console2.log("launchLocker     ", address(d.locker));
        console2.log("splitterFactory  ", address(d.splitterFactory));
        console2.log("launchRouter     ", address(d.router));
        console2.log("launch fee (wei) ", d.factory.launchFee());
        console2.log("launches enabled ", d.factory.launchEnabled());
        console2.log("owner            ", d.owner);
        if (d.ownershipPending) console2.log("OWNER must call acceptOwnership() on factory, memeHook, buybackVault and launchLocker");

        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "factory", address(d.factory));
        vm.serializeAddress(k, "launchDeployer", address(d.launchDeployer));
        vm.serializeAddress(k, "graduationExecutor", address(d.executor));
        vm.serializeAddress(k, "graduationGuard", address(d.factory.graduationGuard()));
        vm.serializeAddress(k, "memeHook", address(d.hook));
        vm.serializeAddress(k, "feeEscrow", address(d.escrow));
        vm.serializeAddress(k, "buybackVault", address(d.vault));
        vm.serializeAddress(k, "launchLocker", address(d.locker));
        vm.serializeAddress(k, "splitterFactory", address(d.splitterFactory));
        vm.serializeAddress(k, "launchRouter", address(d.router));
        vm.serializeAddress(k, "poolManager", manager);
        vm.serializeAddress(k, "positionManager", posm);
        vm.serializeAddress(k, "permit2", permit2);
        vm.serializeAddress(k, "protocolFeeRecipient", protocol);
        string memory json = vm.serializeAddress(k, "owner", d.owner);
        if (vm.envOr("WRITE_DEPLOYMENT", true)) vm.writeJson(json, string.concat("deployments/", vm.toString(block.chainid), ".json"));
    }
}
