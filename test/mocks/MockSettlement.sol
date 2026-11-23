// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { GPv2Order } from "cowprotocol/contracts/libraries/GPv2Order.sol";

import { Silo } from "../../src/Silo.sol";
import { ISettlement } from "../../src/interfaces/ISettlement.sol";

contract MockSettlement is ISettlement {
    using GPv2Order for GPv2Order.Data;

    bytes32 public immutable override domainSeparator;
    address public immutable override vaultRelayer;
    mapping(bytes orderUid => uint256) public override filledAmount;

    constructor(bytes32 domainSeparator_, address vaultRelayer_) {
        domainSeparator = domainSeparator_;
        vaultRelayer = vaultRelayer_;
    }

    /// @dev Mirrors the CoW Settlement flow. Pre-interactions and signature checks share one transaction context.
    function commitAndValidate(Silo silo, GPv2Order.Data calldata order)
        external
        returns (bool observedCommitment, bytes4 result)
    {
        silo.commit(order);
        return _validate(silo, order);
    }

    /// @dev Commits and validates two orders in one simulated settlement transaction.
    function commitAndValidateTwo(Silo silo, GPv2Order.Data[2] calldata orders)
        external
        returns (bool[2] memory observedCommitments, bytes4[2] memory results)
    {
        silo.commit(orders[0]);
        silo.commit(orders[1]);
        (observedCommitments[0], results[0]) = _validate(silo, orders[0]);
        (observedCommitments[1], results[1]) = _validate(silo, orders[1]);
    }

    function _validate(Silo silo, GPv2Order.Data calldata order) private view returns (bool, bytes4) {
        bytes32 digest = order.hash(domainSeparator);
        return (silo.isCommitted(digest), silo.isValidSignature(digest, abi.encode(order)));
    }
}
