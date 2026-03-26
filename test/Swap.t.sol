// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Swap} from "../src/abstracts/Swap.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";

contract MockSwapToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSwapPermit2 {
    address public lastToken;
    address public lastSpender;
    uint160 public lastAmount;
    uint48 public lastExpiration;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        lastToken = token;
        lastSpender = spender;
        lastAmount = amount;
        lastExpiration = expiration;
    }
}

contract MockSwapQuoter {
    uint256 internal quoteAmount;

    function setQuoteAmount(uint256 amount) external {
        quoteAmount = amount;
    }

    function quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams calldata)
        external
        view
        returns (uint256 amountOut, uint256 gasEstimate)
    {
        return (quoteAmount, 0);
    }
}

contract MockSwapRouter {
    address internal payoutToken;
    uint256 internal payoutAmount;
    bool internal payNative;

    receive() external payable {}

    function setPayout(address token, uint256 amount, bool native_) external {
        payoutToken = token;
        payoutAmount = amount;
        payNative = native_;
    }

    function execute(bytes calldata, bytes[] calldata, uint256) external payable {
        if (payNative) {
            payable(msg.sender).transfer(payoutAmount);
        } else {
            ERC20(payoutToken).transfer(msg.sender, payoutAmount);
        }
    }
}

contract MockSwapRegistry {
    address public router;
    address public permit2;
    address public quoter;

    constructor(address _router, address _permit2, address _quoter) {
        router = _router;
        permit2 = _permit2;
        quoter = _quoter;
    }
}

contract SwapHarness is Swap {
    constructor(address registry) Swap(registry) {}

    receive() external payable {}

    function exposedSwap(PoolKey memory key, uint128 amountIn, uint128 minAmountOut, bool isCurrency0FundraisingToken)
        external
        returns (uint256)
    {
        return swapExactInputSingle(key, amountIn, minAmountOut, isCurrency0FundraisingToken);
    }

    function exposedApprove(address token, uint160 amount, uint48 expiration) external {
        approveTokenWithPermit2(token, amount, expiration);
    }

    function exposedQuote(PoolKey memory key, bool zeroForOne, uint128 exactAmount, bytes memory hookData)
        external
        returns (uint256)
    {
        return getMinAmountOut(key, zeroForOne, exactAmount, hookData);
    }
}

contract SwapTest is Test {
    MockSwapToken internal tokenIn;
    MockSwapToken internal tokenOut;
    MockSwapPermit2 internal permit2;
    MockSwapQuoter internal quoter;
    MockSwapRouter internal router;
    MockSwapRegistry internal registry;
    SwapHarness internal harness;

    function setUp() public {
        tokenIn = new MockSwapToken("IN", "IN");
        tokenOut = new MockSwapToken("OUT", "OUT");
        permit2 = new MockSwapPermit2();
        quoter = new MockSwapQuoter();
        router = new MockSwapRouter();
        registry = new MockSwapRegistry(address(router), address(permit2), address(quoter));
        harness = new SwapHarness(address(registry));

        tokenIn.mint(address(harness), 1_000 ether);
    }

    function testConstructorRejectsZeroRegistry() public {
        vm.expectRevert(Swap.ZeroAddress.selector);
        new SwapHarness(address(0));
    }

    function testApproveTokenWithPermit2ForwardsApproval() public {
        harness.exposedApprove(address(tokenIn), 123, 456);

        assertEq(permit2.lastToken(), address(tokenIn));
        assertEq(permit2.lastSpender(), address(router));
        assertEq(permit2.lastAmount(), 123);
        assertEq(permit2.lastExpiration(), 456);
    }

    function testGetMinAmountOutUsesConfiguredQuoteAndSlippageFactor() public {
        PoolKey memory key = _poolKey(address(tokenIn), address(tokenOut));
        quoter.setQuoteAmount(200 ether);

        uint256 minAmountOut = harness.exposedQuote(key, true, 10 ether, bytes(""));

        assertEq(minAmountOut, 10 ether);
    }

    function testSwapExactInputSingleForErc20OutputWhenFundraisingTokenIsCurrency0() public {
        PoolKey memory key = _poolKey(address(tokenIn), address(tokenOut));
        tokenOut.mint(address(router), 25 ether);
        router.setPayout(address(tokenOut), 25 ether, false);

        uint256 amountOut = harness.exposedSwap(key, 10 ether, 1 ether, true);

        assertEq(amountOut, 25 ether);
        assertEq(tokenOut.balanceOf(address(harness)), 25 ether);
        assertEq(permit2.lastToken(), address(tokenIn));
    }

    function testSwapExactInputSingleForErc20OutputWhenFundraisingTokenIsCurrency1() public {
        PoolKey memory key = _poolKey(address(tokenOut), address(tokenIn));
        tokenOut.mint(address(router), 12 ether);
        router.setPayout(address(tokenOut), 12 ether, false);

        uint256 amountOut = harness.exposedSwap(key, 10 ether, 1 ether, false);

        assertEq(amountOut, 12 ether);
        assertEq(tokenOut.balanceOf(address(harness)), 12 ether);
        assertEq(permit2.lastToken(), address(tokenIn));
    }

    function testSwapExactInputSingleForNativeOutput() public {
        PoolKey memory key = _poolKey(address(tokenIn), address(0));
        vm.deal(address(router), 3 ether);
        router.setPayout(address(0), 3 ether, true);

        uint256 amountOut = harness.exposedSwap(key, 10 ether, 1, true);

        assertEq(amountOut, 3 ether);
        assertEq(address(harness).balance, 3 ether);
    }

    function _poolKey(address currency0, address currency1) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });
    }
}
