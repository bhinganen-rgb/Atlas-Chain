// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title AtlasChain - crowdsourced fact registry with challenge/vote arbitration
contract AtlasChain is Ownable, ReentrancyGuard, Pausable {
    enum Status { Pending, Challenged, Verified, Rejected }

    struct Vote {
        bool voted;
        bool supportChallenge;
        uint256 stake;
        bool claimed;
    }

    struct Claim {
        address submitter;
        string topic;
        string claim;
        string sourceUrl;
        uint256 submittedAt;
        Status status;

        address challenger;
        string challengeReason;
        uint256 challengedAt;
        uint256 submissionDeposit;
        uint256 challengeDeposit;

        // vote weights (stake sums)
        uint256 votesForChallenge;
        uint256 votesAgainstChallenge;

        // pools for payout math
        uint256 winningVoterStakePool;   // sum of stakes on the winning side (fixed at resolve)
        uint256 losingVoterStakePool;    // sum of stakes on the losing side minus platform fee (fixed at resolve)

        bool submitterClaimed;
        bool challengerClaimed;
        bool resolved;   // set true when either finalizeUnchallenged or resolveChallenge finishes
    }

    uint256 public claimCount;
    mapping(uint256 => Claim) private _claims;
    mapping(uint256 => mapping(address => Vote)) private _votes;
    mapping(bytes32 => uint256[]) private _byTopic;

    uint256 public submissionDeposit = 0.005 ether;
    uint256 public challengeWindow = 3 days;
    uint256 public votingWindow = 3 days;
    uint256 public platformFeeBps = 500; // 5%
    uint256 public accruedFees;

    uint256 private constant BPS = 10_000;

    event ClaimSubmitted(uint256 indexed claimId, address indexed submitter, bytes32 indexed topicHash, string topic, string claim, string sourceUrl, uint256 deposit);
    event ClaimChallenged(uint256 indexed claimId, address indexed challenger, string reason, uint256 deposit);
    event VoteCast(uint256 indexed claimId, address indexed voter, bool supportChallenge, uint256 stake);
    event ChallengeResolved(uint256 indexed claimId, bool challengerWon, uint256 votesFor, uint256 votesAgainst);
    event ClaimFinalized(uint256 indexed claimId);
    event PayoutClaimed(uint256 indexed claimId, address indexed who, uint256 amount);

    constructor() Ownable(msg.sender) {}

    // ---------- lifecycle ----------

    function submitClaim(string calldata topic, string calldata claimText, string calldata sourceUrl)
        external payable whenNotPaused nonReentrant returns (uint256 claimId)
    {
        require(msg.value == submissionDeposit, "wrong deposit");
        require(bytes(topic).length > 0 && bytes(topic).length <= 80, "topic len");
        require(bytes(claimText).length > 0 && bytes(claimText).length <= 800, "claim len");
        require(bytes(sourceUrl).length > 0 && bytes(sourceUrl).length <= 400, "source len");

        claimId = ++claimCount;
        Claim storage c = _claims[claimId];
        c.submitter = msg.sender;
        c.topic = topic;
        c.claim = claimText;
        c.sourceUrl = sourceUrl;
        c.submittedAt = block.timestamp;
        c.status = Status.Pending;
        c.submissionDeposit = msg.value;

        bytes32 h = keccak256(bytes(topic));
        _byTopic[h].push(claimId);

        emit ClaimSubmitted(claimId, msg.sender, h, topic, claimText, sourceUrl, msg.value);
    }

    function challengeClaim(uint256 claimId, string calldata reason)
        external payable whenNotPaused nonReentrant
    {
        Claim storage c = _claims[claimId];
        require(c.submitter != address(0), "no claim");
        require(c.status == Status.Pending, "not pending");
        require(block.timestamp <= c.submittedAt + challengeWindow, "window closed");
        require(msg.sender != c.submitter, "self challenge");
        require(msg.value == c.submissionDeposit, "match deposit");
        require(bytes(reason).length > 0 && bytes(reason).length <= 400, "reason len");

        c.status = Status.Challenged;
        c.challenger = msg.sender;
        c.challengeReason = reason;
        c.challengedAt = block.timestamp;
        c.challengeDeposit = msg.value;

        emit ClaimChallenged(claimId, msg.sender, reason, msg.value);
    }

    function voteOnChallenge(uint256 claimId, bool supportChallenge)
        external payable whenNotPaused nonReentrant
    {
        Claim storage c = _claims[claimId];
        require(c.status == Status.Challenged, "not challenged");
        require(block.timestamp <= c.challengedAt + votingWindow, "voting closed");
        require(msg.value > 0, "no stake");
        require(msg.sender != c.submitter && msg.sender != c.challenger, "party cannot vote");

        Vote storage v = _votes[claimId][msg.sender];
        require(!v.voted, "already voted");

        v.voted = true;
        v.supportChallenge = supportChallenge;
        v.stake = msg.value;

        if (supportChallenge) c.votesForChallenge += msg.value;
        else c.votesAgainstChallenge += msg.value;

        emit VoteCast(claimId, msg.sender, supportChallenge, msg.value);
    }

    function finalizeUnchallenged(uint256 claimId) external nonReentrant {
        Claim storage c = _claims[claimId];
        require(c.submitter != address(0), "no claim");
        require(c.status == Status.Pending, "not pending");
        require(block.timestamp > c.submittedAt + challengeWindow, "window open");

        c.status = Status.Verified;
        c.resolved = true;
        emit ClaimFinalized(claimId);
    }

    function resolveChallenge(uint256 claimId) external nonReentrant {
        Claim storage c = _claims[claimId];
        require(c.status == Status.Challenged, "not challenged");
        require(block.timestamp > c.challengedAt + votingWindow, "voting open");

        // tie -> defender wins (claim stands)
        bool challengerWon = c.votesForChallenge > c.votesAgainstChallenge;

        uint256 winningVoterPool = challengerWon ? c.votesForChallenge : c.votesAgainstChallenge;
        uint256 losingVoterPool  = challengerWon ? c.votesAgainstChallenge : c.votesForChallenge;

        // Platform fee taken from loser voter pool only (voter-side fee)
        uint256 voterFee = (losingVoterPool * platformFeeBps) / BPS;
        c.winningVoterStakePool = winningVoterPool;
        c.losingVoterStakePool  = losingVoterPool - voterFee;
        accruedFees += voterFee;

        // Fee taken from losing party's deposit only (party-side fee)
        // Winning party will collect their own deposit + (loser deposit - fee) in claimStake.
        // We just mark resolved and account fees.
        uint256 partyLoserDeposit = challengerWon ? c.submissionDeposit : c.challengeDeposit;
        uint256 partyFee = (partyLoserDeposit * platformFeeBps) / BPS;
        accruedFees += partyFee;

        c.status = challengerWon ? Status.Rejected : Status.Verified;
        c.resolved = true;

        emit ChallengeResolved(claimId, challengerWon, c.votesForChallenge, c.votesAgainstChallenge);
    }

    // ---------- payouts ----------

    /// Unified claim function. Pays out whichever roles the caller has an unclaimed entitlement in.
    function claimStake(uint256 claimId) external nonReentrant {
        Claim storage c = _claims[claimId];
        require(c.resolved, "not resolved");

        uint256 payout;

        // Voter payout
        Vote storage v = _votes[claimId][msg.sender];
        if (v.voted && !v.claimed) {
            v.claimed = true;
            // If claim was finalized-unchallenged there was never voting; skip.
            if (c.status == Status.Verified || c.status == Status.Rejected) {
                bool challengerWon = (c.status == Status.Rejected);
                bool winningSide = (v.supportChallenge == challengerWon);
                if (winningSide && c.winningVoterStakePool > 0) {
                    // return own stake + pro-rata share of loser pool
                    uint256 share = (v.stake * c.losingVoterStakePool) / c.winningVoterStakePool;
                    payout += v.stake + share;
                }
                // losing side: 0
            }
        }

        // Submitter payout
        if (msg.sender == c.submitter && !c.submitterClaimed) {
            if (c.status == Status.Verified) {
                c.submitterClaimed = true;
                // If unchallenged: refund submission deposit
                if (c.challenger == address(0)) {
                    payout += c.submissionDeposit;
                } else {
                    // Defender won: get own deposit back + (challenger deposit - party fee)
                    uint256 partyFee = (c.challengeDeposit * platformFeeBps) / BPS;
                    payout += c.submissionDeposit + (c.challengeDeposit - partyFee);
                }
            } else if (c.status == Status.Rejected) {
                // Submitter lost their deposit; still mark claimed to prevent re-entry
                c.submitterClaimed = true;
            }
        }

        // Challenger payout
        if (msg.sender == c.challenger && c.challenger != address(0) && !c.challengerClaimed) {
            if (c.status == Status.Rejected) {
                c.challengerClaimed = true;
                uint256 partyFee = (c.submissionDeposit * platformFeeBps) / BPS;
                payout += c.challengeDeposit + (c.submissionDeposit - partyFee);
            } else if (c.status == Status.Verified) {
                c.challengerClaimed = true; // lost, nothing to claim
            }
        }

        require(payout > 0, "nothing to claim");
        (bool ok,) = msg.sender.call{value: payout}("");
        require(ok, "xfer fail");
        emit PayoutClaimed(claimId, msg.sender, payout);
    }

    // ---------- views ----------

    function getClaim(uint256 claimId) external view returns (
        address submitter, string memory topic, string memory claimText, string memory sourceUrl,
        uint256 submittedAt, uint8 status, address challenger, string memory challengeReason,
        uint256 challengedAt, uint256 votesForChallenge, uint256 votesAgainstChallenge
    ) {
        Claim storage c = _claims[claimId];
        return (c.submitter, c.topic, c.claim, c.sourceUrl, c.submittedAt, uint8(c.status),
                c.challenger, c.challengeReason, c.challengedAt, c.votesForChallenge, c.votesAgainstChallenge);
    }

    function getClaimsByTopic(bytes32 topicHash) external view returns (uint256[] memory) {
        return _byTopic[topicHash];
    }

    function getVoteInfo(uint256 claimId, address voter) external view returns (
        bool voted, bool supportChallenge, uint256 stake, bool claimed
    ) {
        Vote storage v = _votes[claimId][voter];
        return (v.voted, v.supportChallenge, v.stake, v.claimed);
    }

    function getRecent(uint256 startId, uint256 limit) external view returns (uint256[] memory ids) {
        if (startId == 0 || startId > claimCount || limit == 0) return new uint256[](0);
        uint256 count = startId < limit ? startId : limit;
        ids = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            ids[i] = startId - i;
        }
    }

    function getDeposits(uint256 claimId) external view returns (uint256 subDeposit, uint256 chalDeposit) {
        Claim storage c = _claims[claimId];
        return (c.submissionDeposit, c.challengeDeposit);
    }

    // ---------- admin ----------

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function setSubmissionDeposit(uint256 v) external onlyOwner {
        require(v > 0 && v <= 1 ether, "range");
        submissionDeposit = v;
    }

    function setChallengeWindow(uint256 s) external onlyOwner {
        require(s >= 1 days && s <= 30 days, "range");
        challengeWindow = s;
    }

    function setVotingWindow(uint256 s) external onlyOwner {
        require(s >= 1 days && s <= 30 days, "range");
        votingWindow = s;
    }

    function setPlatformFeeBps(uint256 bps) external onlyOwner {
        require(bps <= 1000, "max 10%");
        platformFeeBps = bps;
    }

    function withdrawFees(address payable to) external onlyOwner nonReentrant {
        require(to != address(0), "to=0");
        uint256 amt = accruedFees;
        accruedFees = 0;
        (bool ok,) = to.call{value: amt}("");
        require(ok, "xfer fail");
    }

    receive() external payable {}
}
