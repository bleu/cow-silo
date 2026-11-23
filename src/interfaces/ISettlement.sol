// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

/// @notice The subset of the CoW Protocol settlement interface that Silo uses.
interface ISettlement {
    function domainSeparator() external view returns (bytes32);
    function filledAmount(bytes calldata orderUid) external view returns (uint256);
    function vaultRelayer() external view returns (address);
}
