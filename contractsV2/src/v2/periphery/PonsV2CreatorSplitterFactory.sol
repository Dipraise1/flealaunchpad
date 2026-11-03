// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPonsV2FeeEscrow} from "../interfaces/ILaunchpadV2.sol";
import {PonsV2CreatorSplitter} from "./PonsV2CreatorSplitter.sol";

/**
 * @title PonsV2CreatorSplitterFactory
 * @notice Deploys cheap EIP-1167 clones of PonsV2CreatorSplitter. Frontend
 * flow: call `predictSplitter` (or `createSplitter`) first, then launch with
 * `creatorFeeRecipient` set to that address. The launch factory exempts the
 * creator fee recipient from the snipe tax automatically.
 *
 * The salt is namespaced by the payee set, shares and admin, so a predicted
 * address can only ever hold a splitter with exactly those terms; nobody can
 * front-run the address with different payees.
 */
contract PonsV2CreatorSplitterFactory {
    error CloneFailed();

    event SplitterCreated(address indexed splitter, address indexed creator, address indexed admin);

    address public immutable implementation;
    IPonsV2FeeEscrow public immutable feeEscrow;

    constructor(IPonsV2FeeEscrow feeEscrow_) {
        feeEscrow = feeEscrow_;
        implementation = address(new PonsV2CreatorSplitter());
    }

    function createSplitter(address admin, address[] calldata payees, uint256[] calldata shares, bytes32 salt)
        external
        returns (address splitter)
    {
        bytes32 s = _salt(admin, payees, shares, salt);
        address impl = implementation;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, impl))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            splitter := create2(0, ptr, 0x37, s)
        }
        if (splitter == address(0)) revert CloneFailed();
        PonsV2CreatorSplitter(payable(splitter)).initialize(feeEscrow, admin, payees, shares);
        emit SplitterCreated(splitter, msg.sender, admin);
    }

    function predictSplitter(address admin, address[] calldata payees, uint256[] calldata shares, bytes32 salt)
        external
        view
        returns (address)
    {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", implementation, hex"5af43d82803e903d91602b57fd5bf3"
            )
        );
        bytes32 s = _salt(admin, payees, shares, salt);
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), s, initCodeHash)))));
    }

    function _salt(address admin, address[] calldata payees, uint256[] calldata shares, bytes32 salt)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(admin, payees, shares, salt));
    }
}
