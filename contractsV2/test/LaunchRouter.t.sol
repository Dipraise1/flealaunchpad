// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FleaLaunchRouter} from "../src/v2/periphery/FleaLaunchRouter.sol";
import {FleaV2LaunchFactory} from "../src/v2/FleaV2LaunchFactory.sol";
import {FleaV2CreatorSplitterFactory} from "../src/v2/periphery/FleaV2CreatorSplitterFactory.sol";

/// Stands in for the factory so the router's own rules can be tested on chosen token addresses.
contract StubFactory {
    address public nextToken;
    uint256 public launchFee = 0.0005 ether;
    address public lastDeployer;

    function setNextToken(address t) external { nextToken = t; }

    function launchTokenFor(FleaV2LaunchFactory.TokenParams calldata, uint256, address, address originalDeployer, address[] calldata)
        external
        payable
        returns (address token, address curve)
    {
        require(msg.value == launchFee, "fee");
        lastDeployer = originalDeployer;
        return (nextToken, address(0xC0FFEE));
    }
}

contract LaunchRouterTest is Test {
    StubFactory internal factory;
    FleaLaunchRouter internal router;
    address internal creator = makeAddr("creator");

    function setUp() public {
        factory = new StubFactory();
        router = new FleaLaunchRouter(FleaV2LaunchFactory(payable(address(factory))), FleaV2CreatorSplitterFactory(address(1)));
        vm.deal(creator, 1 ether);
    }

    function _launch(address token, bool requirePrefix, uint256 value) internal returns (address) {
        factory.setNextToken(token);
        FleaV2LaunchFactory.TokenParams memory p;
        FleaLaunchRouter.Split memory none;
        vm.prank(creator);
        (address t,,,) = router.launch{value: value}(p, 0, new address[](0), none, 0, 0, requirePrefix);
        return t;
    }

    function test_acceptsATokenWhoseAddressStartsWithFlea() public {
        address flea = address((uint160(0xf1ea) << 144) | 0xBEEF);
        assertEq(_launch(flea, true, 0.0005 ether), flea);
        assertEq(factory.lastDeployer(), creator, "the real caller is passed on as the deployer");
    }

    function test_refusesAnyOtherAddressWhenThePrefixIsRequired() public {
        address plain = address((uint160(0xf1eb) << 144) | 0xBEEF);
        factory.setNextToken(plain);
        FleaV2LaunchFactory.TokenParams memory p;
        FleaLaunchRouter.Split memory none;
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(FleaLaunchRouter.TokenAddressNotFlea.selector, plain));
        router.launch{value: 0.0005 ether}(p, 0, new address[](0), none, 0, 0, true);
    }

    function test_prefixIsOptionalAndOverpaymentComesBack() public {
        address plain = address((uint160(0x1234) << 144) | 0x1234);
        assertEq(_launch(plain, false, 0.3 ether), plain);
        assertEq(creator.balance, 1 ether - 0.0005 ether, "only the launch fee was kept");
        assertEq(address(router).balance, 0);
    }

    function test_revertsWhenValueDoesNotCoverTheFee() public {
        factory.setNextToken(address(1));
        FleaV2LaunchFactory.TokenParams memory p;
        FleaLaunchRouter.Split memory none;
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(FleaLaunchRouter.InsufficientValue.selector, 0.0005 ether, 0.0001 ether));
        router.launch{value: 0.0001 ether}(p, 0, new address[](0), none, 0, 0, false);
    }
}
