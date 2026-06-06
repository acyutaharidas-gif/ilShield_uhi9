// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ─────────────────────────────────────────────────────────────────────────────
//  script/ILShield_Anvil.s.sol
//
//  PURPOSE
//  -------
//  All-in-one local development script.  Mirrors exactly what the Foundry test
//  suite does in setUp() but as a deployable script you can run against a live
//  local Anvil node.  Useful for:
//    - Quick smoke-tests before submitting to testnet
//    - Connecting the HTML demo frontend to a local node
//    - Manual walkthroughs of the full lifecycle
//
//  WHAT IT DOES (in order)
//  -----------------------
//  1. Deploys fresh PoolManager + PositionManager (not using Sepolia addresses)
//  2. Deploys two mock ERC-20 tokens (TokenA, TokenB)
//  3. Mines a CREATE2 salt and deploys ILShieldHook
//  4. Initializes the pool in PoolManager
//  5. Calls hook.initializePool()
//  6. Mints test tokens to the deployer wallet
//  7. Approves and funds the insurance reserve (20 tokens)
//  8. Logs all addresses so you can wire them into the frontend / Etherscan
//
//  RUN
//  ---
//    # terminal 1
//    anvil
//
//    # terminal 2
//    forge script script/ILShield_Anvil.s.sol          \
//      --rpc-url http://localhost:8545                   \
//      --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
//      --broadcast -vvvv
//
//  NOTE: The private key above is Anvil's default #0 account — safe for local
//        development only.  Never use it on a real network.
// ─────────────────────────────────────────────────────────────────────────────

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {ILShieldHook} from "../src/ILShieldHook.sol";

// ── Minimal mock ERC-20 (no external dependency needed for local testing) ────
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 amount
    );

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max)
            allowance[from][msg.sender] = allowed - amount;
        return _transfer(from, to, amount);
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

// ── Minimal PoolManager stub for Anvil ───────────────────────────────────────
// On Anvil we deploy the real PoolManager from the v4-core package.
// (The test's BaseTest.deployArtifactsAndLabel() does the same via deployCode.)

contract ILShieldAnvilScript is Script {
    // CREATE2 proxy (same address on Anvil as on mainnet/testnet,
    // as long as foundryup is up-to-date)
    address constant CREATE2_DEPLOYER =
        0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 constant MINT_AMOUNT = 1_000_000e18;
    uint256 constant RESERVE_SEED = 20e18;

    using PoolIdLibrary for PoolKey;

    function run() external {
        vm.startBroadcast();

        // ── 1. Deploy mock tokens ─────────────────────────────────────────────
        MockERC20 tokenA = new MockERC20("Token A", "TKA");
        MockERC20 tokenB = new MockERC20("Token B", "TKB");

        // Sort so currency0 < currency1 (required by v4 PoolKey)
        address addr0;
        address addr1;
        if (uint160(address(tokenA)) < uint160(address(tokenB))) {
            addr0 = address(tokenA);
            addr1 = address(tokenB);
        } else {
            addr0 = address(tokenB);
            addr1 = address(tokenA);
        }
        Currency currency0 = Currency.wrap(addr0);
        Currency currency1 = Currency.wrap(addr1);

        console.log("TOKEN0 (lower addr):", addr0);
        console.log("TOKEN1 (higher addr):", addr1);

        // ── 2. Deploy v4 PoolManager ─────────────────────────────────────────
        // deployCode uses Foundry's artifact system — requires the v4-core
        // package to be installed via `forge install uniswap/v4-core`.
        // address pmAddr = deployCode("PoolManager.sol:PoolManager");
        PoolManager pm = new PoolManager(msg.sender);
        address pmAddr = address(pm);
        IPoolManager poolManager = IPoolManager(pmAddr);
        console.log("PoolManager:", pmAddr);

        // ── 3. Mine salt and deploy ILShieldHook ─────────────────────────────
        uint160 flags = uint160(
            Hooks.AFTER_ADD_LIQUIDITY_FLAG |
                Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
                Hooks.AFTER_SWAP_FLAG |
                Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        bytes memory constructorArgs = abi.encode(poolManager);
        (address hookAddr, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(ILShieldHook).creationCode,
            constructorArgs
        );
        console.log("Hook address (mined):", hookAddr);

        ILShieldHook hook = new ILShieldHook{salt: salt}(poolManager);
        require(
            address(hook) == hookAddr,
            "Anvil script: hook address mismatch"
        );
        console.log("ILShieldHook deployed:", address(hook));

        // ── 4. Initialize pool in PoolManager ────────────────────────────────
        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        int24 tick = poolManager.initialize(poolKey, SQRT_PRICE_1_1);
        console.log("Pool initialized at tick:", vm.toString(tick));

        // ── 5. Register pool in the hook ─────────────────────────────────────
        hook.initializePool(poolKey);
        console.log("Hook pool initialized. Default config written.");

        // ── 6. Mint test tokens to deployer ──────────────────────────────────
        address deployer = msg.sender;
        MockERC20(addr0).mint(deployer, MINT_AMOUNT);
        MockERC20(addr1).mint(deployer, MINT_AMOUNT);
        console.log("Minted", MINT_AMOUNT, "of each token to deployer");

        // ── 7. Fund the insurance reserve ────────────────────────────────────
        MockERC20(addr1).approve(address(hook), RESERVE_SEED);
        hook.fundReserve(poolKey, RESERVE_SEED);

        PoolId pid = poolKey.toId();
        uint256 reserve = hook.insuranceReserve(pid);
        require(
            reserve == RESERVE_SEED,
            "Anvil script: reserve not funded correctly"
        );

        vm.stopBroadcast();

        // ── 8. Print deployment summary ──────────────────────────────────────
        console.log("============================================");
        console.log("ILShield Anvil deployment complete");
        console.log("============================================");
        console.log("PoolManager  :", pmAddr);
        console.log("ILShieldHook :", address(hook));
        console.log("TOKEN0       :", addr0);
        console.log("TOKEN1       :", addr1);
        console.log("Reserve      :", reserve);

        ILShieldHook.PoolConfig memory cfg = hook.getPoolConfig(pid);
        console.log("coveragePct  :", cfg.coveragePct);
        console.log("deductibleBps:", cfg.deductibleBps);
        console.log("premiumBps   :", cfg.premiumBps);
        console.log("minLock (s)  :", cfg.minLockSeconds);
        console.log("============================================");
    }
}
