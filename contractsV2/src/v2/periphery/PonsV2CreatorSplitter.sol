// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPonsV2FeeEscrow} from "../interfaces/ILaunchpadV2.sol";

interface ISplitterCurve {
    function sweepFees(uint256 minBuybackTokensOut) external;
}

interface ISplitterHook {
    function sweepPoolFees(PoolId poolId, uint256 minConversionQuoteOut, uint256 minBuybackTokensOut) external;
}

interface ISplitterVault {
    function release(address token) external returns (uint256);
}

interface ISplitterFactory {
    function setBuybackEnabled(address token, bool enabled) external;
}

/**
 * @title PonsV2CreatorSplitter
 * @notice Shared creator for one or more launches. Set a splitter as a
 * launch's `creatorFeeRecipient` and every creator-side payout (curve fees,
 * creator tax, graduated-pool fees, vested buyback tokens) is credited to it
 * in the fee escrow, then split between co-creators by fixed shares.
 *
 * Payees and shares are fixed at creation and nothing can change them, so
 * each co-creator's cut is guaranteed by code rather than by trust in whoever
 * deployed it. The splitter deliberately has no way to call
 * `transferCreatorFeeRecipient`, so no one can redirect the fee stream away
 * from it later.
 *
 * Everything that moves money is permissionless: anyone can pull the
 * splitter's escrow balance and push each payee their share, and anyone can
 * trigger the fee sweeps the creator role is allowed to trigger. The only
 * privileged action is toggling buybacks, held by an optional `admin`.
 *
 * Accounting follows the pull-payment splitter pattern: for each asset,
 * `totalReceived = balance + totalReleased`, and a payee is owed
 * `totalReceived * shares / totalShares - released`. Any amount sent here
 * directly, not only escrow claims, is split the same way.
 *
 * @dev Deployed as EIP-1167 clones by PonsV2CreatorSplitterFactory, so it is
 * initialized once instead of constructed. The implementation contract locks
 * itself in its constructor.
 */
contract PonsV2CreatorSplitter {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_PAYEES = 20;

    error AlreadyInitialized();
    error InvalidPayees();
    error DuplicatePayee(address payee);
    error NotPayee(address account);
    error NotAdmin();
    error NothingDue();
    error TransferFailed();
    error Reentrancy();

    event Initialized(address indexed admin, address[] payees, uint256[] shares);
    event PaymentReleased(address indexed asset, address indexed payee, uint256 amount);
    event PaymentReceived(address indexed from, uint256 amount);

    IPonsV2FeeEscrow public feeEscrow;
    address public admin;
    uint256 public totalShares;
    address[] private _payees;
    mapping(address payee => uint256) public shares;

    // asset == address(0) is native ETH.
    mapping(address asset => uint256) public totalReleased;
    mapping(address asset => mapping(address payee => uint256)) public released;

    bool private _initialized;
    bool private _entered;

    modifier nonReentrant() {
        if (_entered) revert Reentrancy();
        _entered = true;
        _;
        _entered = false;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor() {
        _initialized = true;
    }

    /**
     * @param feeEscrow_ The launchpad's shared fee escrow.
     * @param admin_ Optional; may toggle buybacks. Zero means nobody can.
     * @param payees_ Co-creators, unique and non-zero, at most MAX_PAYEES.
     * @param shares_ Relative weights, any positive numbers (e.g. bps summing to 10_000).
     */
    function initialize(
        IPonsV2FeeEscrow feeEscrow_,
        address admin_,
        address[] calldata payees_,
        uint256[] calldata shares_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        if (address(feeEscrow_) == address(0)) revert InvalidPayees();
        uint256 n = payees_.length;
        if (n == 0 || n > MAX_PAYEES || n != shares_.length) revert InvalidPayees();

        uint256 total;
        for (uint256 i = 0; i < n; ++i) {
            address payee = payees_[i];
            if (payee == address(0) || shares_[i] == 0) revert InvalidPayees();
            if (shares[payee] != 0) revert DuplicatePayee(payee);
            shares[payee] = shares_[i];
            _payees.push(payee);
            total += shares_[i];
        }
        totalShares = total;
        feeEscrow = feeEscrow_;
        admin = admin_;
        emit Initialized(admin_, payees_, shares_);
    }

    receive() external payable {
        emit PaymentReceived(msg.sender, msg.value);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function payees() external view returns (address[] memory) {
        return _payees;
    }

    /// @notice What `payee` can be paid in `asset` right now, from funds already held here.
    function releasable(address asset, address payee) public view returns (uint256) {
        uint256 totalReceived = _balance(asset) + totalReleased[asset];
        uint256 entitled = (totalReceived * shares[payee]) / totalShares;
        uint256 paid = released[asset][payee];
        return entitled > paid ? entitled - paid : 0;
    }

    /// @notice What is still waiting in the fee escrow for this splitter in `asset`.
    function pendingInEscrow(address asset) public view returns (uint256) {
        return asset == address(0) ? feeEscrow.balanceOf(address(this)) : feeEscrow.balanceOfToken(address(this), asset);
    }

    // ------------------------------------------------------------------
    // Money movement (permissionless)
    // ------------------------------------------------------------------

    /// @notice Pulls this splitter's escrow balance in `asset` into the splitter.
    function pullFromEscrow(address asset) public nonReentrant returns (uint256 amount) {
        if (pendingInEscrow(asset) == 0) return 0;
        amount = asset == address(0) ? feeEscrow.claim() : feeEscrow.claimToken(asset);
    }

    /// @notice Pays `payee` everything they are owed in `asset`.
    function release(address asset, address payee) public nonReentrant returns (uint256 amount) {
        if (shares[payee] == 0) revert NotPayee(payee);
        amount = releasable(asset, payee);
        if (amount == 0) revert NothingDue();
        released[asset][payee] += amount;
        totalReleased[asset] += amount;
        _send(asset, payee, amount);
        emit PaymentReleased(asset, payee, amount);
    }

    /// @notice Pulls from escrow, then pays every payee their share of `asset`.
    function distribute(address asset) external {
        pullFromEscrow(asset);
        uint256 n = _payees.length;
        for (uint256 i = 0; i < n; ++i) {
            address payee = _payees[i];
            if (releasable(asset, payee) != 0) release(asset, payee);
        }
    }

    // ------------------------------------------------------------------
    // Creator-role actions
    // ------------------------------------------------------------------

    /**
     * @notice Sweeps a bonding curve whose creator is this splitter. The curve
     * itself refuses a creator sweep while a buyback is pending (that needs
     * the protocol's sweep operator), so this cannot be used to force a
     * badly-priced buyback.
     */
    function sweepCurveFees(address curve) external {
        ISplitterCurve(curve).sweepFees(0);
    }

    /// @notice Sweeps a graduated pool whose creator is this splitter; same operator rule as above.
    function sweepPoolFees(address hook, PoolId poolId) external {
        ISplitterHook(hook).sweepPoolFees(poolId, 0, 0);
    }

    /// @notice Releases vested buyback tokens to the escrow; `distribute(token)` then splits them.
    function releaseVest(address vault, address token) external returns (uint256) {
        return ISplitterVault(vault).release(token);
    }

    function setBuybackEnabled(address launchFactory, address token, bool enabled) external onlyAdmin {
        ISplitterFactory(launchFactory).setBuybackEnabled(token, enabled);
    }

    /// @notice Hands the admin role on, or renounces it with the zero address.
    function setAdmin(address newAdmin) external onlyAdmin {
        admin = newAdmin;
    }

    // ------------------------------------------------------------------

    function _balance(address asset) private view returns (uint256) {
        return asset == address(0) ? address(this).balance : IERC20(asset).balanceOf(address(this));
    }

    function _send(address asset, address to, uint256 amount) private {
        if (asset == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }
}
