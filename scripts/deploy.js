const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  const bal = await hre.ethers.provider.getBalance(deployer.address);
  console.log("Deployer:", deployer.address);
  console.log("Balance :", hre.ethers.formatEther(bal), "BOT");

  const F = await hre.ethers.getContractFactory("AtlasChain");
  const c = await F.deploy();
  await c.waitForDeployment();
  const addr = await c.getAddress();

  console.log("AtlasChain deployed to:", addr);
  console.log("Update CONTRACT_ADDRESS in frontend/index.html");
}

main().catch((e) => { console.error(e); process.exit(1); });
