// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";
import {IAllowanceTransfer} from "lib/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {ETHToWstETHSwapHook} from "src/periphery/ETHToWrappedLSTSwapHook/ETHToWstETHSwapHook.sol";
import {IV4Router} from "lib/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

contract DeployETHToWstETHSwapHookScript is Script {
    using SafeERC20 for IERC20;

    // ── Infrastructure ───────────────────────────────────────────────────────
    IPoolManager constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IUniversalRouter constant UNIVERSAL_ROUTER = IUniversalRouter(0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af);
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // ── Vaults & wrappers ────────────────────────────────────────────────────
    IERC4626 constant EULER_WETH_VAULT = IERC4626(0xc97AF70AB043927A5d9b682e77d1AF3c52559A4e);
    IERC4626 constant ST_ETH_SMOOTH_VAULT = IERC4626(0xb531939Ec3247cd3C55722ae9756a52eBd166bA4);
    IERC4626 constant EWETH_VAULT_WRAPPER = IERC4626(0x5bfADf221F712A301c6B02c89D24B044777b67AB);
    IERC4626 constant SY_STETH_VAULT_WRAPPER = IERC4626(0x6bf9Ed639Bae32095078A9f03F001735CAaF52BC);

    // ── Pool parameters ──────────────────────────────────────────────────────
    IHooks constant YIELD_HARVESTING_HOOK = IHooks(0x777ADCF55501b3494a188cb8dBE415CF8d942a80);
    uint24 constant FEE = 100; // 0.01%
    int24 constant TICK_SPACING = 1;

    // ── Tokens ───────────────────────────────────────────────────────────────
    address constant WST_ETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    Currency constant ETH_CURRENCY = Currency.wrap(address(0));
    Currency constant WST_ETH_CURRENCY = Currency.wrap(WST_ETH);

    // Hook flags required by ETHToWstETHSwapHook
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    function run() external {
        // ── 1. Mine hook salt (off-chain, before broadcast) ──────────────────
        bytes memory constructorArgs = abi.encode(
            POOL_MANAGER,
            EULER_WETH_VAULT,
            ST_ETH_SMOOTH_VAULT,
            EWETH_VAULT_WRAPPER,
            SY_STETH_VAULT_WRAPPER,
            YIELD_HARVESTING_HOOK,
            FEE,
            TICK_SPACING
        );

        (address expectedAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, HOOK_FLAGS, type(ETHToWstETHSwapHook).creationCode, constructorArgs);

        console.log("Mined hook address:", expectedAddress);
        console.log("Salt:", vm.toString(salt));

        // ── 2. Deploy hook ───────────────────────────────────────────────────
        vm.startBroadcast();

        ETHToWstETHSwapHook hook = new ETHToWstETHSwapHook{salt: salt}(
            POOL_MANAGER,
            EULER_WETH_VAULT,
            ST_ETH_SMOOTH_VAULT,
            EWETH_VAULT_WRAPPER,
            SY_STETH_VAULT_WRAPPER,
            YIELD_HARVESTING_HOOK,
            FEE,
            TICK_SPACING
        );

        require(address(hook) == expectedAddress, "Hook address mismatch");
        console.log("ETHToWstETHSwapHook deployed at:", address(hook));

        // ── 3. Pool key for ETH / wstETH pool ───────────────────────────────
        PoolKey memory poolKey = PoolKey({
            currency0: ETH_CURRENCY,
            currency1: WST_ETH_CURRENCY,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // ── 4. Add warm liquidity ────────────────────────────────────────────
        // ETH side: send 0.1 ETH directly to the hook
        uint256 warmLiquidityETH = 0.001 ether;
        hook.addWarmLiquidityETH{value: warmLiquidityETH}();
        console.log("Warm liquidity ETH added:", warmLiquidityETH);

        // wstETH side: approve the hook to spend wstETH, then add
        // The caller must hold enough wstETH before running this script.
        uint256 warmLiquidityWstETH = 0.001 ether; // ~0.1 ETH worth (1 wstETH ≈ 1.18 ETH)
        IERC20(WST_ETH).forceApprove(address(hook), warmLiquidityWstETH);
        hook.addWarmLiquidityLST(warmLiquidityWstETH);
        console.log("Warm liquidity wstETH added:", warmLiquidityWstETH);

        // ── 5. Swap A: ETH → wstETH via Universal Router (warm path) ────────
        uint128 ethAmountIn = 0.001 ether;

        bytes memory actionsETHtoWST = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE), // swap
            uint8(Actions.SETTLE_ALL), // pay ETH debt
            uint8(Actions.TAKE_ALL) // receive wstETH
        );

        bytes[] memory paramsETHtoWST = new bytes[](3);
        paramsETHtoWST[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: true, // ETH (currency0) → wstETH (currency1)
                amountIn: ethAmountIn,
                amountOutMinimum: 0, // no slippage protection in this demo
                hookData: ""
            })
        );
        paramsETHtoWST[1] = abi.encode(ETH_CURRENCY, ethAmountIn); // SETTLE_ALL: (currency, maxAmount)
        paramsETHtoWST[2] = abi.encode(WST_ETH_CURRENCY, uint256(0)); // TAKE_ALL: (currency, minAmount)

        uint256 wstETHBefore = IERC20(WST_ETH).balanceOf(msg.sender);

        UNIVERSAL_ROUTER.execute{value: ethAmountIn}(
            abi.encodePacked(bytes1(0x10)), // 0x10 = V4_SWAP
            _toInputsArray(abi.encode(actionsETHtoWST, paramsETHtoWST)),
            block.timestamp + 60
        );

        uint256 wstETHReceived = IERC20(WST_ETH).balanceOf(msg.sender) - wstETHBefore;
        console.log("ETH in:      ", ethAmountIn);
        console.log("wstETH out:  ", wstETHReceived);

        // ── 6. Swap B: wstETH → ETH via Universal Router (warm path) ────────
        uint128 wstETHAmountIn = uint128(wstETHReceived);
        require(wstETHAmountIn > 0, "No wstETH received from swap A");

        // Approve wstETH → Permit2 → Universal Router
        IERC20(WST_ETH).forceApprove(PERMIT2, type(uint256).max);
        IAllowanceTransfer(PERMIT2).approve(WST_ETH, address(UNIVERSAL_ROUTER), type(uint160).max, type(uint48).max);

        bytes memory actionsWSTtoETH = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE), // swap
            uint8(Actions.SETTLE_ALL), // pay wstETH debt (pulled via Permit2)
            uint8(Actions.TAKE_ALL) // receive ETH
        );

        bytes[] memory paramsWSTtoETH = new bytes[](3);
        paramsWSTtoETH[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: false, // wstETH (currency1) → ETH (currency0)
                amountIn: wstETHAmountIn,
                amountOutMinimum: 0, // no slippage protection in this demo
                hookData: ""
            })
        );
        paramsWSTtoETH[1] = abi.encode(WST_ETH_CURRENCY, wstETHAmountIn); // SETTLE_ALL
        paramsWSTtoETH[2] = abi.encode(ETH_CURRENCY, uint256(0)); // TAKE_ALL

        uint256 ethBefore = msg.sender.balance;

        UNIVERSAL_ROUTER.execute(
            abi.encodePacked(bytes1(0x10)), // 0x10 = V4_SWAP
            _toInputsArray(abi.encode(actionsWSTtoETH, paramsWSTtoETH)),
            block.timestamp + 60
        );

        uint256 ethReceived = msg.sender.balance - ethBefore;
        console.log("wstETH in:   ", wstETHAmountIn);
        console.log("ETH out:     ", ethReceived);

        vm.stopBroadcast();
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function _toInputsArray(bytes memory input) internal pure returns (bytes[] memory arr) {
        arr = new bytes[](1);
        arr[0] = input;
    }
}
