pragma solidity ^0.6.7;

import "ds-test/test.sol";

import "./RadicleLbp.sol";

contract RadicleLbpTest is DSTest {
    RadicleLbp lbp;

    function setUp() public {
        lbp = new RadicleLbp();
    }

    function testFail_basic_sanity() public {
        assertTrue(false);
    }

    function test_basic_sanity() public {
        assertTrue(true);
    }
}
