// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    FeePolicySnapshot, IERC721ReceiverLike, IPonsV2FeeEscrow, IPonsV2LaunchFactory
} from "./interfaces/ILaunchpadV2.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

interface ILockerFactoryView is IPonsV2LaunchFactory {
    function getLaunchFeePolicy(address token) external view returns (FeePolicySnapshot memory);
    function feeEscrow() external view returns (IPonsV2FeeEscrow);
}

interface ILockerCurveView {
    function buybackBurn() external view returns (bool);
}

interface ILockerBurnable {
    function burn(uint256 amount) external;
}

/**
 * @title PonsV2LaunchLocker
 * @notice Permanently holds the graduated Uniswap V4 position NFT for every
 * pons v2 launch. Unlike v1's locker, there is no `collectFees()` here: fee
 * collection and distribution belong entirely to PonsV2MemeHook and
 * PonsV2FeeEscrow, since a V4 position accrues fees inside the singleton
 * PoolManager rather than on the NFT itself. This contract exposes no
 * withdrawal or arbitrary-call function, so locked liquidity can never be
 * removed by an administrator.
 */
contract PonsV2LaunchLocker is Ownable2Step, IERC721ReceiverLike {
    using SafeERC20 for IERC20;

    error NotFactory();
    error AlreadyInitialized();
    error ZeroAddress();
    error PositionAlreadyLocked();
    error PositionNotHeld();
    error NotPositionManager();
    error OwnershipCannotBeRenounced();
    error PositionNotLocked();
    error UnexpectedNativeSender();

    event FactorySet(address factory);
    event PositionLocked(address indexed token, uint256 indexed tokenId);
    event TokenSupplyLocked(address indexed token, uint256 amount);
    event LpFeesCollected(
        address indexed token, uint256 quoteToProtocol, uint256 quoteToCreator, uint256 memeToRecipients, uint256 memeBurned
    );

    address public immutable positionManager;
    address public factory;

    mapping(address token => uint256 tokenId) public lockedPositions;
    mapping(address token => uint256 amount) public lockedTokenSupply;
    mapping(address token => bool locked) private _locked;

    /**
     * @param initialOwner Administrative owner; only used to wire the factory once.
     * @param positionManager_ The canonical Uniswap V4 PositionManager for this chain.
     */
    constructor(address initialOwner, address positionManager_) Ownable(initialOwner) {
        if (positionManager_ == address(0)) revert ZeroAddress();
        positionManager = positionManager_;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    /**
     * @notice One-time wiring of the v2 factory, set after both are deployed.
     */
    function setFactory(address factory_) external onlyOwner {
        if (factory != address(0)) revert AlreadyInitialized();
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
        emit FactorySet(factory_);
    }

    /**
     * @notice Permanently disabled. Ownership here exists only to perform the
     * one-time factory wiring, and renouncing before that wiring would leave
     * the locker unable to ever accept a graduated position.
     */
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    /**
     * @notice Rejects safe transfers of anything but a canonical position NFT.
     * @dev Not part of the graduation path. Graduation names this locker as
     * the `MINT_POSITION` owner, and the PositionManager mints with a plain
     * `_mint`, which fires no receiver callback. Custody is established by
     * the `ownerOf` check in `lockPosition` instead. This exists so the
     * locker still behaves correctly under an explicit `safeTransferFrom`,
     * and so such a transfer can only ever originate from the canonical
     * PositionManager.
     */
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != positionManager) revert NotPositionManager();
        return IERC721ReceiverLike.onERC721Received.selector;
    }

    /**
     * @notice Registers and verifies permanent custody of a graduated position.
     * @dev Called once per launch by the factory, immediately after minting
     * the full-range position directly to this locker's address.
     */
    function lockPosition(address token, uint256 tokenId) external onlyFactory {
        if (_locked[token]) revert PositionAlreadyLocked();
        if (IERC721(positionManager).ownerOf(tokenId) != address(this)) revert PositionNotHeld();

        _locked[token] = true;
        lockedPositions[token] = tokenId;
        emit PositionLocked(token, tokenId);
    }

    /**
     * @notice Permanently locks the virtual-reserve token remainder that
     * cannot enter the graduated pool without lowering its opening price.
     */
    function lockTokenSupply(address token, uint256 amount) external onlyFactory {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) return;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        lockedTokenSupply[token] += amount;
        emit TokenSupplyLocked(token, amount);
    }

    /**
     * @notice Returns whether a launch's position has been locked here.
     */
    function isLocked(address token) external view returns (bool) {
        return _locked[token];
    }

    /**
     * @notice Collects the locked position's accrued LP fees and distributes
     * them. Permissionless: the liquidity itself never moves (the decrease is
     * for zero liquidity, which in V4 only settles owed fees), so the
     * position stays locked forever.
     *
     * The quote leg is split protocol / creator with the launch's frozen
     * protocol share and credited in the fee escrow. The memecoin leg is
     * burned when the launch chose burn-mode buybacks, otherwise split the
     * same way. Revenue here comes from the pool's native LP fee, which
     * every router already prices, so unlike the hook cut it does not depend
     * on aggregator support for return-delta hooks.
     */
    function collectFees(address token) external returns (uint256 amount0, uint256 amount1) {
        if (!_locked[token]) revert PositionNotLocked();
        uint256 tokenId = lockedPositions[token];
        (PoolKey memory key,) = IPositionManager(positionManager).getPoolAndPositionInfo(tokenId);
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);

        uint256 before0 = _balance(c0);
        uint256 before1 = _balance(c1);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        IPositionManager(positionManager).modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)), params),
            block.timestamp
        );
        amount0 = _balance(c0) - before0;
        amount1 = _balance(c1) - before1;

        (address quote, uint256 quoteAmt, uint256 memeAmt) = c0 == token ? (c1, amount1, amount0) : (c0, amount0, amount1);
        _distribute(token, quote, quoteAmt, memeAmt);
    }

    function _distribute(address token, address quote, uint256 quoteAmt, uint256 memeAmt) private {
        ILockerFactoryView f = ILockerFactoryView(factory);
        IPonsV2LaunchFactory.LaunchedToken memory launch = f.getLaunchedToken(token);
        FeePolicySnapshot memory policy = f.getLaunchFeePolicy(token);
        IPonsV2FeeEscrow escrow = f.feeEscrow();

        uint256 qProtocol = (quoteAmt * policy.protocolFeeShareBps) / 10_000;
        _credit(escrow, quote, policy.protocolFeeRecipient, qProtocol);
        _credit(escrow, quote, launch.creatorFeeRecipient, quoteAmt - qProtocol);

        uint256 burned;
        if (memeAmt != 0) {
            if (ILockerCurveView(launch.curve).buybackBurn()) {
                ILockerBurnable(token).burn(memeAmt);
                burned = memeAmt;
            } else {
                uint256 mProtocol = (memeAmt * policy.protocolFeeShareBps) / 10_000;
                _credit(escrow, token, policy.protocolFeeRecipient, mProtocol);
                _credit(escrow, token, launch.creatorFeeRecipient, memeAmt - mProtocol);
            }
        }
        emit LpFeesCollected(token, qProtocol, quoteAmt - qProtocol, memeAmt - burned, burned);
    }

    function _credit(IPonsV2FeeEscrow escrow, address asset, address recipient, uint256 amount) private {
        if (amount == 0) return;
        if (asset == address(0)) {
            escrow.credit{value: amount}(recipient);
        } else {
            IERC20(asset).forceApprove(address(escrow), amount);
            escrow.creditToken(recipient, asset, amount);
        }
    }

    function _balance(address asset) private view returns (uint256) {
        return asset == address(0) ? address(this).balance : IERC20(asset).balanceOf(address(this));
    }

    /// @dev Native LP fees arrive from the pool manager via TAKE_PAIR.
    receive() external payable {
        if (msg.sender != address(IPositionManager(positionManager).poolManager())) revert UnexpectedNativeSender();
    }
}
