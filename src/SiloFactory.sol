// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { IERC20 } from "cowprotocol/contracts/interfaces/IERC20.sol";

import { Silo } from "./Silo.sol";
import { ISettlement } from "./interfaces/ISettlement.sol";

/// @title SiloFactory
/// @notice Deploys discoverable Silo instances at deterministic addresses.
contract SiloFactory {
    ISettlement public immutable settlement;

    event SiloCreated(
        address indexed silo,
        address indexed creator,
        address indexed resourceToken,
        address resourceRecipient,
        bytes32 appData,
        bytes32 userSalt
    );

    error DeploymentFailed();
    error ZeroAddress();

    constructor(ISettlement settlement_) {
        if (address(settlement_) == address(0)) revert ZeroAddress();
        settlement = settlement_;
    }

    function createSilo(IERC20 resourceToken, address resourceRecipient, bytes32 appData, bytes32 userSalt)
        external
        returns (Silo silo)
    {
        bytes32 salt_ = salt(msg.sender, userSalt);
        silo = new Silo{ salt: salt_ }(settlement, resourceToken, resourceRecipient, appData);
        if (address(silo) == address(0)) revert DeploymentFailed();
        emit SiloCreated(address(silo), msg.sender, address(resourceToken), resourceRecipient, appData, userSalt);
    }

    function predictSiloAddress(
        address creator,
        IERC20 resourceToken,
        address resourceRecipient,
        bytes32 appData,
        bytes32 userSalt
    ) external view returns (address predicted) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(Silo).creationCode, abi.encode(settlement, resourceToken, resourceRecipient, appData))
        );
        predicted = address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt(creator, userSalt), initCodeHash)))
            )
        );
    }

    function salt(address creator, bytes32 userSalt) public pure returns (bytes32) {
        return keccak256(abi.encode(creator, userSalt));
    }
}
