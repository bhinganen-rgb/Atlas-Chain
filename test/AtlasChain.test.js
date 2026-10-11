const { expect } = require("chai");
const { ethers, network } = require("hardhat");

const DEPOSIT = ethers.parseEther("0.005");
const DAY = 24 * 60 * 60;

async function increase(sec) {
  await network.provider.send("evm_increaseTime", [sec]);
  await network.provider.send("evm_mine");
}

describe("AtlasChain", () => {
  let atlas, owner, alice, bob, carol, dave, eve;

  beforeEach(async () => {
    [owner, alice, bob, carol, dave, eve] = await ethers.getSigners();
    const F = await ethers.getContractFactory("AtlasChain");
    atlas = await F.deploy();
    await atlas.waitForDeployment();
  });

  it("submitClaim requires exact deposit", async () => {
    await expect(atlas.connect(alice).submitClaim("Tech", "Water boils at 100C", "https://x"))
      .to.be.revertedWith("wrong deposit");
    await expect(atlas.connect(alice).submitClaim("Tech", "Water boils at 100C", "https://x", { value: DEPOSIT }))
      .to.emit(atlas, "ClaimSubmitted");
    expect(await atlas.claimCount()).to.equal(1);
  });

  it("finalizeUnchallenged only after window with no challenge", async () => {
    await atlas.connect(alice).submitClaim("Tech", "c", "https://x", { value: DEPOSIT });
    await expect(atlas.finalizeUnchallenged(1)).to.be.revertedWith("window open");
    await increase(3 * DAY + 1);
    await expect(atlas.finalizeUnchallenged(1)).to.emit(atlas, "ClaimFinalized");
    const c = await atlas.getClaim(1);
    expect(c[5]).to.equal(2); // Verified
  });

  it("challengeClaim requires matching deposit and only in window", async () => {
    await atlas.connect(alice).submitClaim("Tech", "c", "https://x", { value: DEPOSIT });
    await expect(atlas.connect(bob).challengeClaim(1, "wrong", { value: DEPOSIT / 2n }))
      .to.be.revertedWith("match deposit");
    await expect(atlas.connect(bob).challengeClaim(1, "wrong", { value: DEPOSIT }))
      .to.emit(atlas, "ClaimChallenged");
    // second challenge blocked (already challenged)
    await expect(atlas.connect(carol).challengeClaim(1, "again", { value: DEPOSIT }))
      .to.be.revertedWith("not pending");
  });

  it("challenge blocked after window", async () => {
    await atlas.connect(alice).submitClaim("Tech", "c", "https://x", { value: DEPOSIT });
    await increase(3 * DAY + 1);
    await expect(atlas.connect(bob).challengeClaim(1, "late", { value: DEPOSIT }))
      .to.be.revertedWith("window closed");
  });

  it("voteOnChallenge only in voting window and not by parties", async () => {
    await atlas.connect(alice).submitClaim("T", "c", "u", { value: DEPOSIT });
    await atlas.connect(bob).challengeClaim(1, "r", { value: DEPOSIT });
    await expect(atlas.connect(alice).voteOnChallenge(1, false, { value: ethers.parseEther("0.01") }))
      .to.be.revertedWith("party cannot vote");
    await expect(atlas.connect(carol).voteOnChallenge(1, true, { value: 0 }))
      .to.be.revertedWith("no stake");
    await atlas.connect(carol).voteOnChallenge(1, true, { value: ethers.parseEther("0.01") });
    await increase(3 * DAY + 1);
    await expect(atlas.connect(dave).voteOnChallenge(1, true, { value: ethers.parseEther("0.01") }))
      .to.be.revertedWith("voting closed");
  });

  it("resolveChallenge requires window elapsed", async () => {
    await atlas.connect(alice).submitClaim("T", "c", "u", { value: DEPOSIT });
    await atlas.connect(bob).challengeClaim(1, "r", { value: DEPOSIT });
    await expect(atlas.resolveChallenge(1)).to.be.revertedWith("voting open");
    await increase(3 * DAY + 1);
    await expect(atlas.resolveChallenge(1)).to.emit(atlas, "ChallengeResolved");
  });

  it("defender wins: submitter collects fee-deducted challenger deposit", async () => {
    await atlas.connect(alice).submitClaim("T", "c", "u", { value: DEPOSIT });
    await atlas.connect(bob).challengeClaim(1, "r", { value: DEPOSIT });
    await atlas.connect(carol).voteOnChallenge(1, false, { value: ethers.parseEther("0.02") });
    await atlas.connect(dave).voteOnChallenge(1, true,  { value: ethers.parseEther("0.01") });
    await increase(3 * DAY + 1);
    await atlas.resolveChallenge(1);
    const c = await atlas.getClaim(1);
    expect(c[5]).to.equal(2); // Verified

    const fee = DEPOSIT * 500n / 10000n;
    const expected = DEPOSIT + (DEPOSIT - fee);
    const balBefore = await ethers.provider.getBalance(alice.address);
    const tx = await atlas.connect(alice).claimStake(1);
    const rc = await tx.wait();
    const gas = rc.gasUsed * rc.gasPrice;
    const balAfter = await ethers.provider.getBalance(alice.address);
    expect(balAfter - balBefore + gas).to.equal(expected);
  });

  it("challenger wins: challenger collects fee-deducted submitter deposit", async () => {
    await atlas.connect(alice).submitClaim("T", "c", "u", { value: DEPOSIT });
    await atlas.connect(bob).challengeClaim(1, "r", { value: DEPOSIT });
    await atlas.connect(carol).voteOnChallenge(1, true, { value: ethers.parseEther("0.05") });
    await atlas.connect(dave).voteOnChallenge(1, false, { value: ethers.parseEther("0.01") });
    await increase(3 * DAY + 1);
    await atlas.resolveChallenge(1);
    const c = await atlas.getClaim(1);
    expect(c[5]).to.equal(3); // Rejected

    const fee = DEPOSIT * 500n / 10000n;
    const expected = DEPOSIT + (DEPOSIT - fee);
    const balBefore = await ethers.provider.getBalance(bob.address);
    const tx = await atlas.connect(bob).claimStake(1);
    const rc = await tx.wait();
    const gas = rc.gasUsed * rc.gasPrice;
    const balAfter = await ethers.provider.getBalance(bob.address);
    expect(balAfter - balBefore + gas).to.equal(expected);
  });

  it("winning voters split losing voter stakes pro-rata; losers get zero", async () => {
    await atlas.connect(alice).submitClaim("T", "c", "u", { value: DEPOSIT });
    await atlas.connect(bob).challengeClaim(1, "r", { value: DEPOSIT });
    // defender side wins
    await atlas.connect(carol).voteOnChallenge(1, false, { value: ethers.parseEther("0.03") });
    await atlas.connect(dave).voteOnChallenge(1, false, { value: ethers.parseEther("0.01") });
    await atlas.connect(eve).voteOnChallenge(1, true, { value: ethers.parseEther("0.02") });
    await increase(3 * DAY + 1);
    await atlas.resolveChallenge(1);

    const bpsFee = 500n;
    const loserPool = ethers.parseEther("0.02");
    const voterFee = loserPool * bpsFee / 10000n;
    const netLoser = loserPool - voterFee;
    const winPool = ethers.parseEther("0.04");

    // carol: 0.03/0.04 * netLoser + 0.03
    const carolExp = ethers.parseEther("0.03") + (ethers.parseEther("0.03") * netLoser / winPool);
    const balBefore = await ethers.provider.getBalance(carol.address);
    const tx = await atlas.connect(carol).claimStake(1);
    const rc = await tx.wait();
    const gas = rc.gasUsed * rc.gasPrice;
    expect(await ethers.provider.getBalance(carol.address) - balBefore + gas).to.equal(carolExp);

    // eve (loser): reverts because nothing to claim (marks claimed but payout 0)
    await expect(atlas.connect(eve).claimStake(1)).to.be.revertedWith("nothing to claim");
  });

  it("double-vote rejected", async () => {
    await atlas.connect(alice).submitClaim("T", "c", "u", { value: DEPOSIT });
    await atlas.connect(bob).challengeClaim(1, "r", { value: DEPOSIT });
    await atlas.connect(carol).voteOnChallenge(1, true, { value: ethers.parseEther("0.01") });
    await expect(atlas.connect(carol).voteOnChallenge(1, false, { value: ethers.parseEther("0.01") }))
      .to.be.revertedWith("already voted");
  });

  it("double-claim rejected", async () => {
    await atlas.connect(alice).submitClaim("T", "c", "u", { value: DEPOSIT });
    await atlas.connect(bob).challengeClaim(1, "r", { value: DEPOSIT });
    await atlas.connect(carol).voteOnChallenge(1, false, { value: ethers.parseEther("0.02") });
    await atlas.connect(dave).voteOnChallenge(1, true, { value: ethers.parseEther("0.01") });
    await increase(3 * DAY + 1);
    await atlas.resolveChallenge(1);
    await atlas.connect(alice).claimStake(1);
    await expect(atlas.connect(alice).claimStake(1)).to.be.revertedWith("nothing to claim");
  });

  it("pause blocks writes", async () => {
    await atlas.pause();
    await expect(atlas.connect(alice).submitClaim("T", "c", "u", { value: DEPOSIT }))
      .to.be.revertedWithCustomError(atlas, "EnforcedPause");
  });

  it("admin bounds enforced", async () => {
    await expect(atlas.setChallengeWindow(0)).to.be.revertedWith("range");
    await expect(atlas.setVotingWindow(31 * DAY)).to.be.revertedWith("range");
    await expect(atlas.setPlatformFeeBps(2000)).to.be.revertedWith("max 10%");
    await expect(atlas.setSubmissionDeposit(0)).to.be.revertedWith("range");
    await atlas.setPlatformFeeBps(300);
    expect(await atlas.platformFeeBps()).to.equal(300);
  });

  it("topic index correct", async () => {
    await atlas.connect(alice).submitClaim("Science", "a", "u", { value: DEPOSIT });
    await atlas.connect(bob).submitClaim("Science", "b", "u", { value: DEPOSIT });
    await atlas.connect(carol).submitClaim("History", "c", "u", { value: DEPOSIT });
    const hSci = ethers.keccak256(ethers.toUtf8Bytes("Science"));
    const hHist = ethers.keccak256(ethers.toUtf8Bytes("History"));
    const sciIds = await atlas.getClaimsByTopic(hSci);
    const histIds = await atlas.getClaimsByTopic(hHist);
    expect(sciIds.map(x => Number(x))).to.deep.equal([1, 2]);
    expect(histIds.map(x => Number(x))).to.deep.equal([3]);
    const recent = await atlas.getRecent(3, 10);
    expect(recent.map(x => Number(x))).to.deep.equal([3, 2, 1]);
  });

  it("unchallenged submitter refund works", async () => {
    await atlas.connect(alice).submitClaim("T", "c", "u", { value: DEPOSIT });
    await increase(3 * DAY + 1);
    await atlas.finalizeUnchallenged(1);
    const balBefore = await ethers.provider.getBalance(alice.address);
    const tx = await atlas.connect(alice).claimStake(1);
    const rc = await tx.wait();
    const gas = rc.gasUsed * rc.gasPrice;
    expect(await ethers.provider.getBalance(alice.address) - balBefore + gas).to.equal(DEPOSIT);
  });
});
