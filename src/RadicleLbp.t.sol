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
    function getSpotPriceSansFee(address, address) external returns (uint);
    function swapExactAmountIn(address, uint256, address, uint256, uint256) external returns (uint, uint);
    function getDenormalizedWeight(address) external returns (uint256);
    function isPublicSwap() external returns (bool);
}

struct Proposal {
    address proposer;
    uint256 eta;
    address[] targets;
    uint256[] values;
    string[] signatures;
    bytes[] calldatas;
    uint256 startBlock;
    uint256 endBlock;
    uint256 forVotes;
    uint256 againstVotes;
    bool canceled;
    bool executed;
    mapping(address => Receipt) receipts;
}

struct Receipt {
    bool hasVoted;
    bool support;
    uint96 votes;
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

    function swapExactAmountIn(BPool pool, address usdc, uint256 usdcAmount, address rad, uint256 minRadAmount, uint256 maxRadPrice) public returns (uint, uint) {
        IERC20(usdc).approve(address(pool), usdcAmount);
        return pool.swapExactAmountIn(
            usdc, usdcAmount, rad, minRadAmount, maxRadPrice
        );
    }

    function pauseSwapping(IConfigurableRightsPool crpPool) public {
        crpPool.setPublicSwap(false);
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

    function proposeBeginSale(
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

    function proposeExitSale(
        IConfigurableRightsPool crpPool,
        uint poolTokens
    ) public returns (uint) {
        address[] memory targets = new address[](1);
        uint[] memory values = new uint[](1);
        string[] memory sigs = new string[](1);
        bytes[] memory calldatas = new bytes[](1);

        uint[] memory minAmountsOut = new uint[](2);
        minAmountsOut[0] = 2_000_000e18;
        minAmountsOut[1] = 22_000_000e6;

        targets[0] = address(crpPool);
        values[0] = 0;
        sigs[0] = "exitPool(uint256,uint256[])";
        calldatas[0] = abi.encode(poolTokens, minAmountsOut);

        return gov.propose(targets, values, sigs, calldatas, "");
    }

    function proposeExitSaleAndReturnLoan(
        IConfigurableRightsPool crpPool,
        uint poolTokens,
        address usdcToken,
        address lender,
        uint256 loanAmount
    ) public returns (uint) {
        address[] memory targets = new address[](2);
        uint[] memory values = new uint[](2);
        string[] memory sigs = new string[](2);
        bytes[] memory calldatas = new bytes[](2);

        uint[] memory minAmountsOut = new uint[](2);
        minAmountsOut[0] = 2_000_000e18;
        minAmountsOut[1] = 22_000_000e6;

        targets[0] = address(crpPool);
        values[0] = 0;
        sigs[0] = "exitPool(uint256,uint256[])";
        calldatas[0] = abi.encode(poolTokens, minAmountsOut);

        targets[1] = address(usdcToken);
        values[1] = 0;
        sigs[1] = "transfer(address,uint256)";
        calldatas[1] = abi.encode(lender, loanAmount);

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
    Hevm hevm = Hevm(HEVM_ADDRESS);
    User controller;
    User deployer;

    address constant BPOOL_FACTORY = 0x9424B1412450D0f8Fc2255FAf6046b98213B76Bd; // BPool factory (Mainnet)
    address constant CRP_FACTORY   = 0xed52D8E202401645eDAD1c0AA21e872498ce47D0; // CRP factory (Mainnet)
    address constant RAD_ADDR      = 0x31c8EAcBFFdD875c74b94b077895Bd78CF1E64A3; // RAD (Mainnet)
    address constant USDC_ADDR     = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC (Mainnet)
    address constant CONTROLLER    = 0x13075a80df4A80e45e58ef871900F0E0eF2ca5cC; // Pool controller (Mainnet)

    // Durations in blocks.
    uint256 constant WEIGHT_CHANGE_DURATION = 12800; // 2 days
    uint256 constant WEIGHT_CHANGE_DELAY    = 266; // 1 hour

    User foundation;
    Proposer proposer;

    function setUp() public {
        rad        = RadicleToken(RAD_ADDR);
        usdc       = IERC20(USDC_ADDR);
        timelock   = Timelock(0x8dA8f82d2BbDd896822de723F55D6EdF416130ba);
        gov        = Governor(0x690e775361AD66D1c4A25d89da9fCd639F5198eD);
        proposer   = new Proposer(rad, usdc, gov);
        foundation = new User(gov, IERC20(USDC_ADDR));
        controller = new User(gov, IERC20(address(rad)));
        deployer   = new User(gov, IERC20(address(rad)));

        assertEq(address(gov.token()), address(rad));
        assertEq(address(gov.timelock()), address(timelock));
        assertEq(timelock.admin(), address(gov));
        assertEq(gov.guardian(), address(0));

        // Set USDC balance of contract to $10M.
        hevm.store(
            USDC_ADDR,
            keccak256(abi.encode(address(this), uint256(9))),
            bytes32(uint(10_000_000e6))
        );
        // Set RAD balance of contract to 100M.
        hevm.store(
            RAD_ADDR,
            keccak256(abi.encode(address(this), uint256(2))),
            bytes32(uint(100_000_000e18))
        );

        require(address(timelock) != address(0));
        require(address(gov) != address(0));

        assertEq(IERC20Decimal(RAD_ADDR).decimals(), uint(18));
        assertEq(IERC20Decimal(USDC_ADDR).decimals(), uint(6));

        // Transfer enough to make proposals (1%).
        rad.transfer(address(proposer), 1_000_000e18);
        rad.delegate(address(this)); // Delegate our votes to ourselves.
        proposer.delegate(address(proposer));
        hevm.roll(block.number + 1);
    }

    function test_lbp_proposal_begin() public {
        RadicleLbp lbp = RadicleLbp(0x460E22413eE1DCAE311cf90DA83F203E3293A5fF);
        Sale sale = Sale(0x864fDEF96374A2060Ae18f83bbEc924f174D6b35);

        assertEq(address(lbp.sale()), address(sale));

        uint256 saleProposal = 3;

        {
            assertEq(gov.proposalCount(), uint(3), "There are 3 proposals");
            Governor.ProposalState state = gov.state(saleProposal);
            assertTrue(state == Governor.ProposalState.Queued, "Proposal is queued");
        }

        assertEq(sale.radTokenBalance(), lbp.RAD_BALANCE());
        assertEq(sale.usdcTokenBalance(), lbp.USDC_BALANCE());

        IConfigurableRightsPool crpPool = IConfigurableRightsPool(sale.crpPool());
        assertEq(crpPool.getController(), address(sale), "The sale is in control of the CRP");

        uint timelockRad = rad.balanceOf(address(timelock));
        uint timelockUsdc = usdc.balanceOf(address(timelock));

        assertTrue(timelockRad >= lbp.RAD_BALANCE());
        assertTrue(timelockUsdc == lbp.USDC_BALANCE());

        {
            (,uint256 eta,,,,,,) = gov.proposals(saleProposal);
            hevm.warp(eta); // Timelock delay

            Governor.ProposalState state = gov.state(saleProposal);
            assertTrue(state == Governor.ProposalState.Queued, "Proposal is still queued");
        }
        gov.execute(saleProposal);
        assertEq(uint(gov.state(saleProposal)), 7, "Proposal executed");
        assertTrue(crpPool.isPublicSwap(), "Public swapping is enabled");

        {
            // Proposal is now executed. The sale has started.
            BPool bPool = BPool(crpPool.bPool());
            assert(address(bPool) != address(0)); // Pool was created
            assertEq(crpPool.balanceOf(address(timelock)), crpPool.totalSupply(), "Timelock has 100% ownership of the pool");
            assertEq(rad.balanceOf(address(timelock)), timelockRad - lbp.RAD_BALANCE(), "Timelock has less RAD");
            assertEq(usdc.balanceOf(address(timelock)), timelockUsdc - lbp.USDC_BALANCE(), "Timelock has less USDC");
            assertEq(bPool.getController(), address(crpPool), "Pool is controlled by CRP");
            assertEq(bPool.getBalance(address(rad)), lbp.RAD_BALANCE());
            assertEq(bPool.getBalance(address(usdc)), lbp.USDC_BALANCE());
            assertEq(crpPool.getController(), CONTROLLER, "The CRP controller was transferred");

            uint price = bPool.getSpotPriceSansFee(address(usdc), address(rad));
            assertTrue(price < 12e6 && price > 11e6);

            // Try to poke once the initial weight change delay has passed.
            hevm.roll(block.number + WEIGHT_CHANGE_DELAY + 1);
            crpPool.pokeWeights();
            uint newPrice = bPool.getSpotPriceSansFee(address(usdc), address(rad));
            assertTrue(newPrice < price, "Price is lower after poke");

            // Try buying some RAD.
            User buyer = new User(gov, IERC20(address(usdc)));
            usdc.transfer(address(buyer), 500_000e6);
            (uint radAmountOut,) = buyer.swapExactAmountIn(
                bPool,
                address(usdc),
                500_000e6,
                address(rad),
                1,
                21e6
            );
            assertEq(usdc.balanceOf(address(buyer)), 0, "Buyer spent all their USDC");
            assertEq(rad.balanceOf(address(buyer)), radAmountOut, "Buyer received RAD");
            assertTrue(radAmountOut < 50_000e18 && radAmountOut > 40_000e18, "Buyer gets an expected amount of RAD");

            // Fast forward to sale end.
            hevm.roll(block.number + WEIGHT_CHANGE_DURATION + WEIGHT_CHANGE_DELAY);

            crpPool.pokeWeights();
            uint256 radWeight = bPool.getDenormalizedWeight(address(rad));
            uint256 usdcWeight = bPool.getDenormalizedWeight(address(usdc));
            assertEq(radWeight, sale.RAD_END_WEIGHT() * BalancerConstants.BONE, "RAD weights are final");
            assertEq(usdcWeight, sale.USDC_END_WEIGHT() * BalancerConstants.BONE, "USDC weights are final");
        }

        // Sale is now over. Propose to withdraw funds.
        uint256 poolTokens = crpPool.balanceOf(address(timelock));
        assertEq(poolTokens, crpPool.totalSupply(), "Timelock has 100% ownership of the pool");

        uint exitProposal = proposer.proposeExitSale(crpPool, poolTokens - 1e14);
        {
            // Execute proposal.
            hevm.roll(block.number + gov.votingDelay() + 1);
            gov.castVote(exitProposal, true);
            hevm.roll(block.number + gov.votingPeriod());
            gov.queue(exitProposal);
            hevm.warp(block.timestamp + 2 days); // Timelock delay
            gov.execute(exitProposal);

            assertEq(crpPool.balanceOf(address(timelock)), 1e14, "Timelock has traded in most of its pool tokens");
            {
                uint256 finalBalance = usdc.balanceOf(address(timelock));
                uint256 expectedBalance = lbp.USDC_BALANCE() + 500_000e6; // Original amount plus sale.
                // Check that the recovered amount is within 10 USDC of the expected amount.
                assertTrue(expectedBalance - finalBalance <= 10e6, "Timelock recovered the USDC");
            }
        }
    }

    function test_lbp_proposal_end() public {
        RadicleLbp lbp = RadicleLbp(0x460E22413eE1DCAE311cf90DA83F203E3293A5fF);
        Sale sale = Sale(0x864fDEF96374A2060Ae18f83bbEc924f174D6b35);
        IConfigurableRightsPool crpPool = IConfigurableRightsPool(sale.crpPool());

        uint timelockRad = rad.balanceOf(address(timelock));
        uint timelockUsdc = usdc.balanceOf(address(timelock));

        // Sale is now over. Propose to withdraw funds.
        uint256 poolTokens = crpPool.balanceOf(address(timelock));
        assertEq(poolTokens, crpPool.totalSupply(), "Timelock has 100% ownership of the pool");

        address lender = 0x055E29502153aEDcFDaE8Fc15a710FF6fb5e10C9;
        assertEq(usdc.balanceOf(lender), 0, "Lender has no USDC");

        uint remainder = 1e17; // 0.1% of pool tokens.
        uint exitProposal = proposer.proposeExitSaleAndReturnLoan(
            crpPool, poolTokens - remainder, address(usdc), lender, lbp.USDC_BALANCE()
        );

        // Execute proposal.
        hevm.roll(block.number + gov.votingDelay() + 1);
        gov.castVote(exitProposal, true);
        hevm.roll(block.number + gov.votingPeriod());
        gov.queue(exitProposal);
        hevm.warp(block.timestamp + 2 days); // Timelock delay
        gov.execute(exitProposal);

        assertEq(crpPool.balanceOf(address(timelock)), remainder, "Timelock has traded in most of its pool tokens");

        uint256 finalBalance = usdc.balanceOf(address(timelock));
        uint256 expectedBalance = 18_000_000e6; // Sale proceeds.
        // Check that the recovered amount is within 10 USDC of the expected amount.
        assertTrue(finalBalance > expectedBalance, "Timelock recovered the USDC");
        assertTrue(usdc.balanceOf(address(crpPool)) > 0, "CRP Pool still has some USDC tokens");
        assertTrue(rad.balanceOf(address(crpPool)) == 0, "CRP Pool still has no RAD tokens");
        assertTrue(usdc.balanceOf(address(crpPool)) <= 100e6, "CRP Pool has less than or equal 100 USDC");
        assertTrue(rad.balanceOf(address(crpPool)) <= 10e18, "CRP Pool has less than or equal 10 RAD");

        // Check loan returned.
        assertEq(usdc.balanceOf(lender), lbp.USDC_BALANCE(), "Loan returned");
    }

    function test_lbp_proposal() public {
        // Set USDC balance of treasury to 0.
        hevm.store(
            USDC_ADDR,
            keccak256(abi.encode(address(timelock), uint256(9))),
            bytes32(uint(0))
        );

        RadicleLbp lbp = deployer.deployLbp(
            BPOOL_FACTORY,
            CRP_FACTORY,
            address(rad),
            address(usdc),
            address(timelock)
        );
        uint256 radAmount = lbp.RAD_BALANCE();
        uint256 usdAmount = lbp.USDC_BALANCE();
        uint256 timelockInitialRad = rad.balanceOf(address(timelock));
        uint256 timelockInitialUsdc = usdc.balanceOf(address(timelock));

        assertEq(rad.balanceOf(address(proposer)), uint(1_000_000e18));
        assertEq(rad.getCurrentVotes(address(proposer)), uint(1_000_000e18), "Proposer has enough voting power");

        Sale sale = lbp.sale();

        assertEq(sale.radTokenBalance(), radAmount);
        assertEq(sale.usdcTokenBalance(), usdAmount);

        IConfigurableRightsPool crpPool = IConfigurableRightsPool(sale.crpPool());
        assertEq(crpPool.getController(), address(sale), "The sale is in control of the CRP");

        require(address(proposer) != address(0), "Proposer address can't be zero");
        uint saleProposal = proposer.proposeBeginSale(
            address(sale),
            radAmount,
            usdAmount,
            WEIGHT_CHANGE_DURATION,
            WEIGHT_CHANGE_DELAY,
            address(controller)
        );
        assertEq(uint(gov.state(saleProposal)), 0, "Proposal pending");
        hevm.roll(block.number + gov.votingDelay() + 1);
        assertEq(uint(gov.state(saleProposal)), 1, "Proposal active");

        // Vote for the proposal.
        gov.castVote(saleProposal, true);
        // Let some time pass, and check that the proposal succeeded.
        hevm.roll(block.number + gov.votingPeriod());
        assertEq(uint(gov.state(saleProposal)), 4, "Proposal suucceeded");

        // The proposal has now passed, we can queue it and execute it.
        gov.queue(saleProposal);
        assertEq(uint(gov.state(saleProposal)), 5, "Proposal queued");

        // Provide liquidity to treasury during the timelock delay period.
        usdc.transfer(address(timelock), usdAmount);
        rad.transfer(address(timelock), radAmount);

        // Keep track of timelock balances before proposal is executed.
        uint256 timelockRad = rad.balanceOf(address(timelock));
        uint256 timelockUsdc = usdc.balanceOf(address(timelock));

        hevm.warp(block.timestamp + 2 days); // Timelock delay
        gov.execute(saleProposal);
        assertEq(uint(gov.state(saleProposal)), 7, "Proposal executed");

        {
            // Proposal is now executed. The sale has started.
            BPool bPool = BPool(crpPool.bPool());
            assert(address(bPool) != address(0)); // Pool was created
            assertEq(crpPool.balanceOf(address(timelock)), crpPool.totalSupply(), "Timelock has 100% ownership of the pool");
            assertEq(rad.balanceOf(address(timelock)), timelockRad - radAmount, "Timelock has less RAD");
            assertEq(usdc.balanceOf(address(timelock)), timelockUsdc - usdAmount, "Timelock has less USDC");
            assertEq(bPool.getController(), address(crpPool), "Pool is controlled by CRP");
            assertEq(bPool.getBalance(address(rad)), radAmount);
            assertEq(bPool.getBalance(address(usdc)), usdAmount);
            assertEq(crpPool.getController(), address(controller), "The CRP controller was transferred");

            uint price = bPool.getSpotPriceSansFee(address(usdc), address(rad));
            assertTrue(price < 12e6 && price > 11e6);

            // Try buying some RAD.
            User buyer = new User(gov, IERC20(address(usdc)));
            usdc.transfer(address(buyer), 500_000e6);
            (uint radAmountOut,) = buyer.swapExactAmountIn(
                bPool,
                address(usdc),
                500_000e6,
                address(rad),
                1,
                21e6
            );
            assertEq(usdc.balanceOf(address(buyer)), 0, "Buyer spent all their USDC");
            assertEq(rad.balanceOf(address(buyer)), radAmountOut, "Buyer received RAD");

            // Fast forward to sale end.
            hevm.roll(block.number + WEIGHT_CHANGE_DURATION + WEIGHT_CHANGE_DELAY);

            crpPool.pokeWeights();
            uint256 radWeight = bPool.getDenormalizedWeight(address(rad));
            uint256 usdcWeight = bPool.getDenormalizedWeight(address(usdc));
            assertEq(radWeight, sale.RAD_END_WEIGHT() * BalancerConstants.BONE, "RAD weights are final");
            assertEq(usdcWeight, sale.USDC_END_WEIGHT() * BalancerConstants.BONE, "USDC weights are final");

            // Pause swapping.
            controller.pauseSwapping(crpPool);
            assert(!bPool.isPublicSwap());
        }

        // Sale is now over. Propose to withdraw funds.
        uint256 poolTokens = crpPool.balanceOf(address(timelock));
        assertEq(poolTokens, crpPool.totalSupply(), "Timelock has 100% ownership of the pool");

        uint exitProposal = proposer.proposeExitSale(crpPool, poolTokens - 1e14);
        {
            uint timelockRad = rad.balanceOf(address(timelock));
            uint timelockUsdc = usdc.balanceOf(address(timelock));

            assertEq(timelockRad, timelockInitialRad, "Timelock has its initial amount of RAD");
            assertEq(timelockUsdc, timelockInitialUsdc, "Timelock has its initial amount of USDC");

            // Execute proposal.
            hevm.roll(block.number + gov.votingDelay() + 1);
            gov.castVote(exitProposal, true);
            hevm.roll(block.number + gov.votingPeriod());
            gov.queue(exitProposal);
            hevm.warp(block.timestamp + 2 days); // Timelock delay
            gov.execute(exitProposal);

            assertEq(crpPool.balanceOf(address(timelock)), 1e14, "Timelock has traded in most of its pool tokens");
            {
                uint256 finalBalance = usdc.balanceOf(address(timelock));
                uint256 expectedBalance = usdAmount + 500_000e6; // Original amount plus sale.
                // Check that the recovered amount is within 10 USDC of the expected amount.
                assertTrue(expectedBalance - finalBalance <= 10e6, "Timelock recovered the USDC");
            }
        }
    }
}
