// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { IERC20 } from "cowprotocol/contracts/interfaces/IERC20.sol";

import { ISettlement } from "./ISettlement.sol";
import { ISilo } from "./ISilo.sol";

/// @title ISiloFactory
/// @notice Defines deterministic Silo deployment and address prediction.
interface ISiloFactory {
    event SiloCreated(
        address indexed silo,
        address indexed owner,
        address indexed resourceToken,
        address resourceRecipient,
        uint256 minimumBuyAmount,
        bytes32 userSalt
    );

    error ZeroAddress();

    function settlement() external view returns (ISettlement);

    /// @notice Deploys a Silo and assigns ownership to the caller.
    /// @param resourceToken The token received by every valid order.
    /// @param resourceRecipient The fixed recipient of the resource token.
    /// @param minimumBuyAmount The initial output floor in the resource token's smallest unit.
    /// @param userSalt A caller-scoped CREATE2 salt.
    function createSilo(IERC20 resourceToken, address resourceRecipient, uint256 minimumBuyAmount, bytes32 userSalt)
        external
        returns (ISilo silo);

    /// @notice Predicts the address of a Silo deployment.
    function predictSiloAddress(
        address owner,
        IERC20 resourceToken,
        address resourceRecipient,
        uint256 minimumBuyAmount,
        bytes32 userSalt
    ) external view returns (address predicted);

    /// @notice Derives the CREATE2 salt for an owner and user-provided salt.
    function salt(address owner, bytes32 userSalt) external pure returns (bytes32);
}
