// SPDX-License-Identifier: MIT
pragma solidity ^0.7.4;
pragma abicoder v2;

import "ds-test/test.sol";
import "./RadicleLbp.sol";

import {Phase0}       from "radicle-contracts/deploy/phase0.sol";
import {RadicleToken} from "radicle-contracts/Governance/RadicleToken.sol";
import {Governor}     from "radicle-contracts/Governance/Governor.sol";
import {Timelock}     from "radicle-contracts/Governance/Timelock.sol";

import {ENS}          from "@ensdomains/ens/contracts/ENS.sol";
import {DSToken}      from "../lib/ds-token/src/token.sol";

interface Hevm {
    function warp(uint256) external;
    function roll(uint256) external;
    function store(address,bytes32,bytes32) external;
    function sign(uint,bytes32) external returns (uint8,bytes32,bytes32);
    function addr(uint) external returns (address);
}

contract USDUser {
    DSToken usd;

    constructor(DSToken usd_) {
        usd = usd_;
    }

    function transfer(address to, uint amt) public {
        usd.transfer(to, amt);
    }
}

contract RadUser {
    RadicleToken rad;
    Governor     gov;

    constructor(RadicleToken rad_, Governor gov_, Timelock timelock_) {
        rad = rad_;
        gov = gov_;
    }

    function transfer(address to, uint amt) public {
        rad.transfer(to, amt);
    }

    function propose(address target, string memory sig, bytes memory cd) public returns (uint) {
        address[] memory targets = new address[](1);
        uint[] memory values = new uint[](1);
        string[] memory sigs = new string[](1);
        bytes[] memory calldatas = new bytes[](1);

        targets[0] = target;
        values[0] = 0;
        sigs[0] = sig;
        calldatas[0] = cd;

        return gov.propose(targets, values, sigs, calldatas, "");
    }

    function queue(uint proposalId) public {
        gov.queue(proposalId);
    }

    function castVote(uint proposalId, bool support) public {
        gov.castVote(proposalId, support);
    }

    function deployLbp() public {
    }
}

contract RadicleLbpTest is DSTest {
    Governor gov;
    RadicleToken rad;
    DSToken usd;
    Timelock timelock;
    RadicleLbp lbp;
    Hevm hevm = Hevm(HEVM_ADDRESS);

    USDUser foundation;
    RadUser deployer;
    RadUser proposer;

    function setUp() public {
        // Deploy radicle governance.
        Phase0 phase0 = new Phase0(
            address(this),
            address(this),
            2 days,
            address(0),
            ENS(address(this)),
            "namehash",
            "label"
        );
        rad      = phase0.token();
        timelock = phase0.timelock();
        gov      = phase0.governor();

        usd = new DSToken("USDC");
        foundation = new USDUser(usd);

        usd.mint(100_000_000 ether);
        usd.transfer(address(foundation), 3_000_000 ether);
    }

    function test_lbp_proposal() public {
        // 0. Radicle is deployed and liquidity is transfered to treasury
        // 1. Deployer deploys RadicleLbp contract
        // 2. Proposer proposes to create a sale, using the Sale contract
        // 3. Voting begins on proposal
        // 4. After voting period ends, Proposer executes proposal
        // 5. LBP is now created, and buying and selling starts

        // Provide liquidity to treasury.
        foundation.transfer(address(timelock), 3_000_000 ether);
    }
}
