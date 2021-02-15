// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;

import "ds-test/test.sol";
import "./RadicleLbp.sol";

contract RadicleLbpTest is DSTest {
    RadicleLbp lbp;

    function setUp() public {}

    function testFail_basic_sanity() public {
        assertTrue(false);
    }

    function test_basic_sanity() public {
        assertTrue(true);
    }
}
