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

// solhint-disable-next-line no-global-import
import "./Structs.sol";

interface IWormhole {
    function parseAndVerifyVM(bytes calldata encodedVM)
        external
        view
        returns (Structs.VM memory vm, bool valid, string memory reason);
}

/**
 * @title Uniswap Wormhole Message Receiver
 * @dev This contract receives and executes Uniswap governance proposals that were sent from the UniswapWormholeMessageSender
 * contract on Ethereum via Wormhole.
 *
 * It enforces that proposals are executed in order, but it does not guarantee that all proposals are executed.
 * i.e. The message sequence number of proposals must be strictly monotonically increasing, but need not be consecutive
 * The maximum number of proposals that can be received is therefore UINT64_MAX.
 * For example, if there are proposals 1, 2 and 3, then the following are valid executions (not exhaustive):
 * - 1,2,3
 * - 1,3
 * But the following are impossible (not exhaustive):
 * - 1,3,2
 */
contract UniswapWormholeMessageReceiver {
    string public constant NAME = "Uniswap Wormhole Message Receiver";
    bytes32 public constant EXPECTED_MESSAGE_PAYLOAD_VERSION = keccak256(
        abi.encode(
            "UniswapWormholeMessageSenderV1 (bytes32 receivedMessagePayloadVersion, address[] memory targets, uint256[] memory values, bytes[] memory datas, address messageReceiver, uint16 receiverChainId)"
        )
    );

    // Address of the UniswapWormholeMessageSender contract on ethereum in Wormhole format,
    // i.e. 12 zero bytes followed by a 20-byte Ethereum address.
    bytes32 public immutable messageSender;

    // A uint16 definining the destination chain of a VAA this contract will trust
    uint16 public immutable chainId;

    // A uint16 definining the source chain of a VAA this contract will trust
    uint16 public constant ETHEREUM_CHAIN_ID = 2;

    IWormhole private immutable wormhole;

    // the next message must have at least this sequence number
    uint64 public nextMinimumSequence = 0;

    /**
     * Message timeout in seconds: Time out needs to account for:
     * - Finality time on source chain
     * - Time for Wormhole validators to sign and make VAA available to relayers
     * - Time to relay VAA to the target chain
     * - Congestion on target chain leading to delayed inclusion of transaction in target chain
     *
     * Note that there is no way to alter this hard coded value. Including such a feature
     * would require some governance structure and some minumum and maximum values.
     */
    uint256 public constant MESSAGE_TIME_OUT_SECONDS = 2 days;

    /**
     * @param wormholeAddress Address of Wormhole core messaging contract on this chain.
     * @param _messageSender Address of the UniswapWormholeMessageSender contract on ethereum in Wormhole format,
     * i.e. 12 zero bytes followed by a 20-byte Ethereum address.
     */
    constructor(address wormholeAddress, bytes32 _messageSender, uint16 _chainId) {
        // sanity check constructor args
        require(wormholeAddress != address(0), "Invalid wormhole address");
        require(_messageSender != bytes32(0) && bytes12(_messageSender) == 0, "Invalid sender contract");
        require(_chainId != ETHEREUM_CHAIN_ID, "Invalid chainId Ethereum");

        wormhole = IWormhole(wormholeAddress);
        messageSender = _messageSender;
        chainId = _chainId;
    }

    /**
     * @param whMessage Wormhole message relayed from a source chain.
     */
    function receiveMessage(bytes calldata whMessage) external payable {
        (Structs.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(whMessage);

        // validate
        require(valid, reason);

        // ensure the emitterAddress of this VAA is the Uniswap message sender
        require(messageSender == vm.emitterAddress, "Invalid Emitter Address!");

        // ensure the emitterChainId is Ethereum to prevent impersonation
        require(vm.emitterChainId == ETHEREUM_CHAIN_ID, "Invalid Emitter Chain");

        /**
         * Ensure that the sequence field in the VAA is strictly monotonically increasing. This also acts as
         * a replay protection mechanism to ensure that already executed messages don't execute again.
         *
         * WARNING: Be mindful that if the sender is ever adapted to support multiple consistency levels, the sequence number
         * enforcement in the receiver could result in delivery of a message with a higher sequence number first and thus
         * invalidate the lower sequence number message from being processable on the receiver. As long as CONSISTENCY_LEVEL
         * remains a constant this is a non-issue. If this changes, changes to the receiver may be required to address messages
         * of variable consistency.
         */
        require(vm.sequence >= nextMinimumSequence, "Invalid Sequence number");
        // increase nextMinimumSequence
        nextMinimumSequence = vm.sequence + 1;

        // check if the message is still valid as defined by the validity period
        // solhint-disable-next-line not-rely-on-time
        require(vm.timestamp + MESSAGE_TIME_OUT_SECONDS >= block.timestamp, "Message no longer valid");

        // verify destination
        (
            bytes32 receivedMessagePayloadVersion,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            address messageReceiver,
            uint16 receiverChainId
        ) = abi.decode(vm.payload, (bytes32, address[], uint256[], bytes[], address, uint16));
        require(EXPECTED_MESSAGE_PAYLOAD_VERSION == receivedMessagePayloadVersion, "Wrong payload version");
        require(messageReceiver == address(this), "Message not for this dest");
        require(receiverChainId == chainId, "Message not for this chain");

        // cache target length and verify that each argument has the same length
        uint256 targetsLength = targets.length;
        require(targetsLength == calldatas.length && targetsLength == values.length, "Inconsistent argument lengths");

        // verify that the caller sent enough value to make each target call
        require(verifyTargetValues(values), "Incorrect value");

        // execute each message
        for (uint256 i = 0; i < targetsLength;) {
            (bool success,) = targets[i].call{value: values[i]}(calldatas[i]);
            require(success, "Sub-call failed");

            unchecked {
                i += 1;
            }
        }
    }

    function verifyTargetValues(uint256[] memory values) internal view returns (bool) {
        uint256 valuesSum;

        uint256 valuesLength = values.length;
        for (uint256 i = 0; i < valuesLength;) {
            valuesSum += values[i];

            unchecked {
                i += 1;
            }
        }

        return valuesSum == msg.value;
    }
}
