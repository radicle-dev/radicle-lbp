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
import {IERC20}       from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface Hevm {
    function warp(uint256) external;
    function roll(uint256) external;
    function store(address,bytes32,bytes32) external;
    function sign(uint,bytes32) external returns (uint8,bytes32,bytes32);
    function addr(uint) external returns (address);
}

interface BPool {
    function getBalance(address) external returns (uint256);
    function getController() external returns (address);
}

contract User {
    Governor gov;
    IERC20 token;

    constructor(Governor gov_, IERC20 token_) {
        gov = gov_;
        token = token_;
    }

    function transfer(address to, uint amt) public {
        token.transfer(to, amt);
    }

    function queue(uint proposalId) public {
        gov.queue(proposalId);
    }

    function castVote(uint proposalId, bool support) public {
        gov.castVote(proposalId, support);
    }

    function deployLbp(address bPool, address crpPool, address rad, address usd, address lp) public returns (RadicleLbp) {
        require(rad == address(token));
        RadicleLbp lbp = new RadicleLbp(
            bPool,
            crpPool,
            IERC20Decimal(rad),
            IERC20Decimal(usd),
            lp
        );
        return lbp;
    }
}

contract Proposer {
    RadicleToken rad;
    IERC20       usd;
    Governor     gov;

    constructor(RadicleToken rad_, IERC20 usd_, Governor gov_) {
        require(address(gov_) != address(0), "Governance must not be zero");

        rad = rad_;
        usd = usd_;
        gov = gov_;
    }

    function delegate(address addr) public {
        rad.delegate(addr);
    }

    function propose(
        address sale,
        uint256 radAmount,
        uint256 usdAmount,
        uint256 weightChangeDuration,
        uint256 weightChangeDelay,
        address controller
    ) public returns (uint) {
        address[] memory targets = new address[](3);
        uint[] memory values = new uint[](3);
        string[] memory sigs = new string[](3);
        bytes[] memory calldatas = new bytes[](3);

        targets[0] = address(rad);
        values[0] = 0;
        sigs[0] = "approve(address,uint256)";
        calldatas[0] = abi.encode(sale, radAmount);

        targets[1] = address(usd);
        values[1] = 0;
        sigs[1] = "approve(address,uint256)";
        calldatas[1] = abi.encode(sale, usdAmount);

        targets[2] = sale;
        values[2] = 0;
        sigs[2] = "begin(uint256,uint256,address)";
        calldatas[2] = abi.encode(uint256(weightChangeDuration), uint256(weightChangeDelay), controller);

        return gov.propose(targets, values, sigs, calldatas, "");
    }

    function queue(uint proposalId) public {
        gov.queue(proposalId);
    }
}

contract RadicleLbpTest is DSTest {
    Governor gov;
    RadicleToken rad;
    IERC20 usdc;
    Timelock timelock;
    RadicleLbp lbp;
    Hevm hevm = Hevm(HEVM_ADDRESS);

    address constant BPOOL_FACTORY = 0x9424B1412450D0f8Fc2255FAf6046b98213B76Bd; // BPool factory (Mainnet)
    address constant CRP_FACTORY   = 0xed52D8E202401645eDAD1c0AA21e872498ce47D0; // CRP factory (Mainnet)
    address constant RAD_ADDR      = 0x31c8EAcBFFdD875c74b94b077895Bd78CF1E64A3; // RAD (Mainnet)
    address constant USDC_ADDR     = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC (Mainnet)

    // Durations in blocks.
    uint256 constant WEIGHT_CHANGE_DURATION = 12800; // 2 days
    uint256 constant WEIGHT_CHANGE_DELAY    = 266; // 1 hour

    User foundation;
    Proposer proposer;

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
        rad        = phase0.token();
        usdc       = IERC20(USDC_ADDR);
        timelock   = phase0.timelock();
        gov        = phase0.governor();
        proposer   = new Proposer(rad, usdc, gov);
        foundation = new User(gov, IERC20(USDC_ADDR));

        // Set USDC balance of contract to $3M.
        hevm.store(
            USDC_ADDR,
            keccak256(abi.encode(address(this), uint256(9))),
            bytes32(uint(3_000_000e6))
        );

        require(address(timelock) != address(0));
        require(address(gov) != address(0));

        assertEq(IERC20Decimal(RAD_ADDR).decimals(), uint(18));
        assertEq(IERC20Decimal(USDC_ADDR).decimals(), uint(6));

        usdc.transfer(address(foundation), 3_000_000e6);

        // Transfer enough to make proposals (1%).
        rad.transfer(address(proposer), 1_000_000e18);
        rad.delegate(address(this)); // Delegate our votes to ourselves.
        proposer.delegate(address(proposer));
        hevm.roll(block.number + 1);
    }

    function test_lbp_proposal() public {
        // 0. Radicle is deployed and liquidity is transfered to treasury
        // 1. Deployer deploys RadicleLbp contract
        // 2. Proposer proposes to create a sale, using the Sale contract
        // 3. Voting begins on proposal
        // 4. After voting period ends, Proposer executes proposal
        // 5. LBP is now created, and buying and selling starts

        uint256 radAmount = 4_000_000e18;
        uint256 usdAmount = 3_000_000e6;

        assertEq(rad.balanceOf(address(proposer)), uint(1_000_000e18));
        assertEq(rad.getCurrentVotes(address(proposer)), uint(1_000_000e18), "Proposer has enough voting power");
        assertEq(usdc.balanceOf(address(foundation)), uint(3_000_000e6));

        // Provide liquidity to treasury.
        foundation.transfer(address(timelock), usdAmount);

        User deployer = new User(gov, IERC20(address(rad)));
        RadicleLbp lbp = deployer.deployLbp(
            BPOOL_FACTORY,
            CRP_FACTORY,
            address(rad),
            address(usdc),
            address(timelock)
        );
        Sale sale = lbp.sale();

        assertEq(sale.radTokenBalance(), radAmount);
        assertEq(sale.usdcTokenBalance(), usdAmount);

        IConfigurableRightsPool crpPool = IConfigurableRightsPool(sale.crpPool());
        assertEq(crpPool.getController(), address(sale));

        require(address(proposer) != address(0), "Proposer address can't be zero");
        uint proposal = proposer.propose(
            address(sale),
            radAmount,
            usdAmount,
            WEIGHT_CHANGE_DURATION,
            WEIGHT_CHANGE_DELAY,
            address(this)
        );
        hevm.roll(block.number + gov.votingDelay() + 1);
        assertEq(uint(gov.state(proposal)), 1);

        // Vote for the proposal.
        gov.castVote(proposal, true);
        // Let some time pass, and check that the proposal succeeded.
        hevm.roll(block.number + gov.votingPeriod());
        assertEq(uint(gov.state(proposal)), 4);

        // Keep track of timelock balances before proposal is executed.
        uint256 timelockRad = rad.balanceOf(address(timelock));
        uint256 timelockUsdc = usdc.balanceOf(address(timelock));

        // The proposal has now passed, we can queue it and execute it.
        gov.queue(proposal);
        assertEq(uint(gov.state(proposal)), 5);
        hevm.warp(block.timestamp + 2 days); // Timelock delay
        gov.execute(proposal);
        assertEq(uint(gov.state(proposal)), 7);

        // Proposal is now executed. The sale has started.
        BPool bPool = BPool(crpPool.bPool());
        assert(address(bPool) != address(0)); // Pool was created
        assertEq(crpPool.balanceOf(address(timelock)), crpPool.totalSupply(), "Timelock has 100% ownership of the pool");
        assertEq(rad.balanceOf(address(timelock)), timelockRad - radAmount, "Timelock has less RAD");
        assertEq(usdc.balanceOf(address(timelock)), timelockUsdc - usdAmount, "Timelock has less USDC");
        assertEq(bPool.getController(), address(crpPool), "Pool is controlled by CRP");
        assertEq(bPool.getBalance(address(rad)), radAmount);
        assertEq(bPool.getBalance(address(usdc)), usdAmount);
    }
}
