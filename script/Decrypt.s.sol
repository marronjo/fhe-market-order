// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {Token} from "../src/Token.sol";
import {Config} from "./base/Config.sol";

import {euint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {MarketOrder} from "../src/MarketOrder.sol";

contract DecryptScript is Script, Config {
    function setUp() public {}

    function run() public returns(euint128 evalue, bool decrypted) {
        evalue = euint128.wrap(54051747899667180064828506118860784691714079683146417651185615627240528545280);
        decrypted = MarketOrder(address(hookContract)).getOrderDecryptStatus(evalue);
    }
}