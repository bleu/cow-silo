// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { IERC20 } from "cowprotocol/contracts/interfaces/IERC20.sol";

import { Silo } from "./Silo.sol";
import { ISettlement } from "./interfaces/ISettlement.sol";
import { ISilo } from "./interfaces/ISilo.sol";
import { ISiloFactory } from "./interfaces/ISiloFactory.sol";

/// @title SiloFactory
/// @notice Deploys discoverable Silo instances at deterministic addresses.
contract SiloFactory is ISiloFactory {
    ISettlement public immutable override settlement;

    constructor(ISettlement settlement_) {
        if (address(settlement_) == address(0)) revert ZeroAddress();
        settlement = settlement_;
    }

    /// @inheritdoc ISiloFactory
    function createSilo(
        IERC20 resourceToken,
        address resourceRecipient,
        uint256 initialBuyAmount,
        uint256 minimumBuyAmount,
        uint32 auctionDuration,
        bytes32 appData,
        bytes32 userSalt
    ) external override returns (ISilo silo) {
        if (initialBuyAmount == minimumBuyAmount) auctionDuration = 0;
        bytes32 salt_ = salt(msg.sender, userSalt);
        silo = ISilo(
            address(
                new Silo{ salt: salt_ }(
                    settlement,
                    resourceToken,
                    resourceRecipient,
                    initialBuyAmount,
                    minimumBuyAmount,
                    auctionDuration,
                    appData,
                    msg.sender
                )
            )
        );
        emit SiloCreated(
            address(silo),
            msg.sender,
            address(resourceToken),
            resourceRecipient,
            initialBuyAmount,
            minimumBuyAmount,
            auctionDuration,
            appData,
            userSalt
        );
    }

    /// @inheritdoc ISiloFactory
    function predictSiloAddress(
        address owner,
        IERC20 resourceToken,
        address resourceRecipient,
        uint256 initialBuyAmount,
        uint256 minimumBuyAmount,
        uint32 auctionDuration,
        bytes32 appData,
        bytes32 userSalt
    ) external view override returns (address predicted) {
        if (initialBuyAmount == minimumBuyAmount) auctionDuration = 0;
        bytes32 initCodeHash = _initCodeHash(
            owner, resourceToken, resourceRecipient, initialBuyAmount, minimumBuyAmount, auctionDuration, appData
        );
        predicted = address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt(owner, userSalt), initCodeHash)))
            )
        );
    }

    function _initCodeHash(
        address owner,
        IERC20 resourceToken,
        address resourceRecipient,
        uint256 initialBuyAmount,
        uint256 minimumBuyAmount,
        uint32 auctionDuration,
        bytes32 appData
    ) private view returns (bytes32) {
        bytes memory args = abi.encode(
            settlement,
            resourceToken,
            resourceRecipient,
            initialBuyAmount,
            minimumBuyAmount,
            auctionDuration,
            appData,
            owner
        );
        return keccak256(bytes.concat(type(Silo).creationCode, args));
    }

    /// @inheritdoc ISiloFactory
    function salt(address owner, bytes32 userSalt) public pure override returns (bytes32) {
        return keccak256(abi.encode(owner, userSalt));
    }
}
