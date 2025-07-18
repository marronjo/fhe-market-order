// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {Token} from "../src/Token.sol";

contract TokenScript is Script {
    function setUp() public {}

    function run() public returns(Token tokenA, Token tokenB) {
        vm.startBroadcast();
        tokenA = new Token("CIPHER", "CPH");
        tokenB = new Token("MASK", "MSK");

        tokenA.mint(1e25);
        tokenB.mint(1e25);
        vm.stopBroadcast();
    }
}