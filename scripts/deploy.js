// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// You can also run a script with `npx hardhat run <script>`. If you do that, Hardhat
// will compile your contracts, add the Hardhat Runtime Environment's members to the
// global scope, and execute the script.
const hre = require("hardhat");

async function main() {
  // USDC address for Mumbai testnet
  const usdcAddress = "0x0FA8781a83E46826621b3BC094Ea2A0212e71B23";

  const treasury = await hre.ethers.deployContract("Treasury", [usdcAddress]);

  await treasury.waitForDeployment();

  console.log(`Treasury deployed to ${treasury.target}`);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
