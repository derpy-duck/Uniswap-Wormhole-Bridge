/**
 * Copyright Uniswap Foundation 2023
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on
 * an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations under the License.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
pragma solidity ^0.8.7;

import {IWormholeRelayer, VaaKey} from "wormhole-solidity-sdk/interfaces/IWormholeRelayer.sol";
import {toWormholeFormat} from "wormhole-solidity-sdk/Utils.sol";

interface IWormhole {
    function publishMessage(uint32 nonce, bytes memory payload, uint8 consistencyLevel)
        external
        payable
       returns (uint64 sequence);
    function messageFee() external view returns (uint256);
    function chainId() external view returns (uint16);
}

bytes32 constant messagePayloadVersion = keccak256(
    abi.encode(
        "UniswapWormholeMessageSenderV1 (bytes32 receivedMessagePayloadVersion, address[] memory targets, uint256[] memory values, bytes[] memory datas, address messageReceiver, uint16 receiverChainId)"
    )
);

function generateMessagePayload(
    address[] memory _targets,
    uint256[] memory _values,
    bytes[] memory _calldatas,
    address _messageReceiver,
    uint16 _receiverChainId
) pure returns (bytes memory) {
    // SECURITY: Anytime this format is changed, messagePayloadVersion should be updated.
    return abi.encode(messagePayloadVersion, _targets, _values, _calldatas, _messageReceiver, _receiverChainId);
}

contract UniswapWormholeMessageSender {
    string public constant NAME = "Uniswap Wormhole Message Sender";

    // address of the permissioned message sender
    address public owner;

    // `nonce` in Wormhole is a misnomer and can be safely set to a constant value.
    uint32 public constant NONCE = 0;

    /**
     * consistencyLevel = 1 means finalized on Ethereum, see https://book.wormhole.com/wormhole/3_coreLayerContracts.html#consistency-levels
     *
     * WARNING: Be mindful that if the sender is ever adapted to support multiple consistency levels, the sequence number
     * enforcement in the receiver could result in delivery of a message with a higher sequence number first and thus
     * invalidate the lower sequence number message from being processable on the receiver.  As long as CONSISTENCY_LEVEL
     * remains a constant this is a non-issue.  If this changes, changes to the receiver may be required to address messages
     * of variable consistency.
     */
    uint8 public constant CONSISTENCY_LEVEL = 1;

    /**
     * @notice This event is emitted when a Wormhole message is published.
     * @param payload Encoded payload emitted by the Wormhole core contract.
     * @param messageReceiver Recipient contract of the emitted Wormhole message.
     */
    event MessageSent(bytes payload, address indexed messageReceiver);

    // Wormhole core contract interface
    IWormhole private immutable wormhole;
    // Wormhole relaying contract interface
    IWormholeRelayer private immutable wormholeRelayer;

    /**
     * @param wormholeRelayerAddress Address of Wormhole relaying messaging contract on this chain.
     */
    constructor(address wormholeAddress, address wormholeRelayerAddress) {
        // sanity check constructor args
        require(wormholeAddress != address(0), "Invalid wormhole address");
        require(wormholeRelayerAddress != address(0), "Invalid wormhole relayer address");

        wormhole = IWormhole(wormholeAddress);
        wormholeRelayer = IWormholeRelayer(wormholeRelayerAddress);
        owner = msg.sender;
    }

    function quoteMessageFee(uint16 receiverChainId, uint256 receiverValue, uint256 gasLimit) public view returns (uint256 messageFee) {
        uint256 relayingFee;
        (relayingFee,) = wormholeRelayer.quoteEVMDeliveryPrice(receiverChainId, receiverValue, gasLimit);

        messageFee = relayingFee + wormhole.messageFee();
    }

    /**
     * @param targets array of target addresses
     * @param values array of values
     * @param calldatas array of calldatas
     * @param messageReceiver address of the receiver contract
     * @param receiverChainId chain id of the receiver chain
     */
    function sendMessage(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        address messageReceiver,
        uint16 receiverChainId,
        address receiverChainAddress,
        uint256 gasLimit,
        address receiverChainRefundAddress
    ) external payable onlyOwner {
        // cache wormhole instance
        IWormhole _wormhole = wormhole;
        uint256 wormholeMessageFee = wormhole.messageFee();

        uint256 sum = getSum(values);
        uint256 messageFee = quoteMessageFee(receiverChainId, sum, gasLimit);

        require(msg.value == messageFee, "invalid message fee");
        require(receiverChainId != 2, "invalid receiverChainID Ethereum");
        require(receiverChainId != 0, "invalid receiverChainID Unset");

        // format the message payload
        bytes memory payload = generateMessagePayload(targets, values, calldatas, messageReceiver, receiverChainId);

        // publish the payload by invoking the Wormhole core contract
        uint64 sequence = _wormhole.publishMessage{value: wormholeMessageFee}(NONCE, payload, CONSISTENCY_LEVEL);

        VaaKey[] memory vaaKeys = new VaaKey[](1);
        vaaKeys[0] = VaaKey({
            chainId: _wormhole.chainId(),
            emitterAddress: toWormholeFormat(address(this)),
            sequence: sequence
        });

        // request delivery of the payload by invoking the Wormhole relayer contract
        wormholeRelayer.sendVaasToEvm{value: messageFee - wormholeMessageFee}(receiverChainId, receiverChainAddress, bytes(""), sum, gasLimit, vaaKeys, receiverChainId, receiverChainRefundAddress);

        emit MessageSent(payload, messageReceiver);
    }

    /**
     * @notice Transfers ownership to `newOwner`.
     * @param newOwner Address of the `newOwner`.
     */
    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "newOwner cannot equal address(0)");

        owner = newOwner;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "sender not owner");
        _;
    }

    function getSum(uint256[] memory values) internal pure returns (uint256 valuesSum) {
         uint256 valuesLength = values.length;
        for (uint256 i = 0; i < valuesLength;) {
            valuesSum += values[i];
            unchecked {
                i += 1;
            }
        }
    }
}
