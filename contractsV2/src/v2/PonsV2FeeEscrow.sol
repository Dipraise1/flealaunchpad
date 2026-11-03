// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPonsV2FeeEscrow} from "./interfaces/ILaunchpadV2.sol";

/**
 * @title PonsV2FeeEscrow
 * @notice Pull-payment ledger shared by every curve, the meme hook and the
 * buyback vault. Fee legs are credited here instead of pushed to recipients,
 * so a recipient that reverts on receipt (a contract without `receive`, a
 * blacklisted address) can never block a sweep or a graduation.
 *
 * No owner and no admin path: a balance can only ever leave to the address
 * it was credited to.
 *
 * @dev Token credits are measured by balance delta. The meme hook requires
 * the escrow to receive exactly `amount`, so a fee-on-transfer token makes
 * the hook's own exact-delivery check fail rather than this ledger silently
 * over-crediting.
 */
contract PonsV2FeeEscrow is IPonsV2FeeEscrow, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance(uint256 requested, uint256 available);
    error TransferFailed();

    event Credited(address indexed recipient, address indexed token, address indexed from, uint256 amount);
    event Claimed(address indexed recipient, address indexed token, uint256 amount);

    // token == address(0) is native ETH.
    mapping(address recipient => mapping(address token => uint256)) private _balances;

    function credit(address recipient) external payable override {
        if (recipient == address(0)) revert ZeroAddress();
        if (msg.value == 0) return;
        _balances[recipient][address(0)] += msg.value;
        emit Credited(recipient, address(0), msg.sender, msg.value);
    }

    function creditToken(address recipient, address token, uint256 amount) external override nonReentrant {
        if (recipient == address(0) || token == address(0)) revert ZeroAddress();
        if (amount == 0) return;
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        _balances[recipient][token] += received;
        emit Credited(recipient, token, msg.sender, received);
    }

    function claim() external override returns (uint256 amount) {
        return _claimNative(_balances[msg.sender][address(0)]);
    }

    function claim(uint256 amount) external override returns (uint256) {
        return _claimNative(amount);
    }

    function claimToken(address token) external override returns (uint256 amount) {
        return _claimToken(token, _balances[msg.sender][token]);
    }

    function claimToken(address token, uint256 amount) external override returns (uint256) {
        return _claimToken(token, amount);
    }

    function balanceOf(address recipient) external view override returns (uint256) {
        return _balances[recipient][address(0)];
    }

    function balanceOfToken(address recipient, address token) external view override returns (uint256) {
        return _balances[recipient][token];
    }

    function _claimNative(uint256 amount) private nonReentrant returns (uint256) {
        if (amount == 0) revert ZeroAmount();
        uint256 available = _balances[msg.sender][address(0)];
        if (amount > available) revert InsufficientBalance(amount, available);
        _balances[msg.sender][address(0)] = available - amount;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Claimed(msg.sender, address(0), amount);
        return amount;
    }

    function _claimToken(address token, uint256 amount) private nonReentrant returns (uint256) {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 available = _balances[msg.sender][token];
        if (amount > available) revert InsufficientBalance(amount, available);
        _balances[msg.sender][token] = available - amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, token, amount);
        return amount;
    }
}
