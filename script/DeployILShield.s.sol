// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {ILShieldHook} from "../src/ILShieldHook.sol";

// import {Constants} from "../base/Constants.sol";
// import {ILShieldHook} from "../src/ILShieldHook.sol";

/// @notice Mines the address and deploys the ILShieldHook.sol Hook contract
contract ILShieldHookScript is Script {
    function setUp() public {}

    function run() public {
        address POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
        address CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

        // hook contracts must have specific flags encoded in the address
        uint160 FLAGS = uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        // = 0x0544

        // Mine a salt that will produce a hook address with the correct flags
        bytes memory constructorArgs = abi.encode(POOL_MANAGER);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, FLAGS, type(ILShieldHook).creationCode, constructorArgs);

        // Deploy the hook using CREATE2
        vm.broadcast();
        ILShieldHook hook = new ILShieldHook{salt: salt}(IPoolManager(POOL_MANAGER));
        require(address(hook) == hookAddress, "ILShieldHookScript: hook address mismatch");
    }
}