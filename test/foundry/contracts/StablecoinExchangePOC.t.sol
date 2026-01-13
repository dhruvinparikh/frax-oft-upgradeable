// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test, console } from "forge-std/Test.sol";
import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";
import { ITIP20Factory } from "tempo-std/interfaces/ITIP20Factory.sol";
import { ITIP20RolesAuth } from "tempo-std/interfaces/ITIP20RolesAuth.sol";
import { IStablecoinDEX } from "tempo-std/interfaces/IStablecoinDEX.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";

/// @title StablecoinExchange POC Test
/// @notice Verifies tempo-foundry's DEX precompile works correctly
contract StablecoinExchangePOCTest is Test {
    IStablecoinDEX dex = StdPrecompiles.STABLECOIN_DEX;
    ITIP20 pathUsd = ITIP20(StdTokens.PATH_USD_ADDRESS);

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    ITIP20 testToken;

    uint128 constant MIN_ORDER_AMOUNT = 10_000_000;

    function setUp() public {
        testToken = ITIP20(
            ITIP20Factory(address(StdPrecompiles.TIP20_FACTORY)).createToken(
                "Test Token",
                "TEST",
                "USD",
                pathUsd,
                address(this),
                keccak256("test-salt")
            )
        );

        ITIP20RolesAuth(address(testToken)).grantRole(testToken.ISSUER_ROLE(), address(this));
        ITIP20RolesAuth(StdTokens.PATH_USD_ADDRESS).grantRole(pathUsd.ISSUER_ROLE(), address(this));

        testToken.mint(alice, 100_000e6);
        testToken.mint(bob, 100_000e6);
    }

    /// @notice Verifies orders CAN be placed successfully
    function test_PlaceOrder_Works() public {
        dex.createPair(address(testToken));

        pathUsd.mint(alice, 50_000e6);
        vm.startPrank(alice);
        pathUsd.approve(address(dex), type(uint256).max);

        uint128 orderId = dex.place(address(testToken), 20_000e6, true, 0);
        vm.stopPrank();

        assertGt(orderId, 0, "Order should be placed");
        
        // Verify order exists via getOrder
        IStablecoinDEX.Order memory order = dex.getOrder(orderId);
        assertEq(order.maker, alice, "Order maker should be alice");
        assertEq(order.amount, 20_000e6, "Order amount should match");
    }

    /// @notice Verifies bestBidTick is updated after placing orders
    function test_BestBidTick_Updated() public {
        dex.createPair(address(testToken));

        pathUsd.mint(alice, 50_000e6);
        vm.startPrank(alice);
        pathUsd.approve(address(dex), type(uint256).max);
        dex.place(address(testToken), 20_000e6, true, 0);
        vm.stopPrank();

        (, , int16 bestBidTick, ) = dex.books(dex.pairKey(address(testToken), address(pathUsd)));
        assertEq(bestBidTick, 0, "bestBidTick should be updated to 0");
    }

    /// @notice Verifies swap works correctly
    function test_Swap_Works() public {
        dex.createPair(address(testToken));

        // Alice places bid
        pathUsd.mint(alice, 50_000e6);
        vm.startPrank(alice);
        pathUsd.approve(address(dex), type(uint256).max);
        dex.place(address(testToken), 20_000e6, true, 0);
        vm.stopPrank();

        // Bob swaps testToken for PATH_USD
        vm.startPrank(bob);
        testToken.approve(address(dex), type(uint256).max);

        uint128 amountOut = dex.swapExactAmountIn(address(testToken), address(pathUsd), 10_000e6, 1);
        vm.stopPrank();

        assertEq(amountOut, 10_000e6, "Should receive expected PATH_USD");
        assertEq(pathUsd.balanceOf(bob), 10_000e6, "Bob balance should match");
    }

    /// @notice Shows revert tests work correctly
    function test_RevertWhen_NoLiquidity() public {
        dex.createPair(address(testToken));

        vm.startPrank(bob);
        testToken.approve(address(dex), type(uint256).max);

        try dex.swapExactAmountIn(address(testToken), address(pathUsd), 10_000e6, 1) {
            fail("Should revert with InsufficientLiquidity");
        } catch {}
        vm.stopPrank();
    }

    function test_RevertWhen_NoPair() public {
        vm.startPrank(bob);
        testToken.approve(address(dex), type(uint256).max);

        try dex.swapExactAmountIn(address(testToken), address(pathUsd), 10_000e6, 1) {
            fail("Should revert with PairDoesNotExist");
        } catch {}
        vm.stopPrank();
    }
}
