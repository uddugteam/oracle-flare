let sleep = require('util').promisify(setTimeout);
const { ethers } = require('hardhat');
// @ts-ignore
import { time, expectEvent } from '@openzeppelin/test-helpers';
import { toBN } from '../../test/utils/test-helpers';
import { 
    IFtsoRegistryInstance, 
    IVoterWhitelisterInstance,
    IPriceSubmitterInstance,
    IFtsoInstance,
} from "../../typechain-truffle";


async function getTime(): Promise<number>{
    await time.advanceBlock();
    const blockNum = await ethers.provider.getBlockNumber();
    const block = await ethers.provider.getBlock(blockNum);
    const timestamp = block.timestamp;
    return timestamp
}

export function submitPriceHash(price: number, random: number, address: string,): string {
    return ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode([ "uint256", "uint256", "address" ], [ price.toString(), random.toString(), address]))
}

// TODO: Implement this to read prices from interesting places
function getPrice(epochId: number, asset: string): number{
    return Math.floor(Math.random() * 200 + 10000);
}

// TODO: Maybe change random generation
function getRandom(epochId: number, asset: string): number{
    return Math.floor(Math.random() * 1000);
}

const MockPriceSubmitter = artifacts.require("MockPriceSubmitter");
const MockFtsoRegistry = artifacts.require("MockFtsoRegistry");
const MockVoterWhitelister = artifacts.require("MockVoterWhitelister");
const MockFtso = artifacts.require("MockNpmFtso");

async function main() {
    console.log(await getTime());
    console.log((new Date()).getTime());
    // Just the first from autogenerated accounts
    const priceProviderPrivateKey = "0xc5e8f61d1ab959b397eecc0a37a6517b8e67a0e7cf1f4bce5591f3ed80199122";
    const priceProviderAccount = web3.eth.accounts.privateKeyToAccount(priceProviderPrivateKey);

    // Initialize data
    
    // Price submitter is at a fixed address, change this to the address reported by `yarn hh_node`.
    const priceSubmitter: IPriceSubmitterInstance = await MockPriceSubmitter.at("0x7c2C195CD6D34B8F845992d380aADB2730bB9C6F");

    const ftsoRegistry: IFtsoRegistryInstance = await MockFtsoRegistry.at(await priceSubmitter.getFtsoRegistry());
    const voterWhitelister: IVoterWhitelisterInstance = await MockVoterWhitelister.at(await priceSubmitter.getVoterWhitelister());

    // Get indices for specific symbols
    const symbols = ["SGB", "XRP", "LTC", "XLM", "XDG", "ADA", "ALGO", "BCH", "DGB", "BTC"];
    const ftsos = await Promise.all(
        symbols.map(async sym => await MockFtso.at(await ftsoRegistry.getFtsoBySymbol(sym)))
    ) as IFtsoInstance[];

    const ftsoAddresses = await Promise.all(
        symbols.map(async sym => await ftsoRegistry.getFtsoBySymbol(sym))
    );

    // Get indices on which to submit
    const ftsoIndices = await Promise.all(
        symbols.map(async sym => (await ftsoRegistry.getFtsoIndex(sym)).toNumber())
    )

    // Combine them for easier future use
    const currencyIndices = new Map(
        symbols.map((c, i) => [c, ftsoIndices[i]]) 
    );

    // Whitelist ourselves for EVERY ftso. This always works in mock case
    // since there is no vote power calculation, so everyone gets whitelisted.
    // In a real setting, this call can be quite expensive and can potentially fail
    // if the voter does not have enough power or provide enough gas for the transaction
    const tx = await voterWhitelister.requestFullVoterWhitelisting(priceProviderAccount.address);
    // Check the whitelist for any changes
    const whitelist = await priceSubmitter.voterWhitelistBitmap(priceProviderAccount.address);

    // Get submission config
    const {
        0: firstEpochStartTsBN,
        1: submitPeriodSecondsBN,
        2: revealPeriodSecondsBN,
    } = (await ftsos[0].getPriceEpochConfiguration());

    const [firstEpochStartTs, submitPeriodSeconds, revealPeriodSeconds] = 
        [firstEpochStartTsBN, submitPeriodSecondsBN, revealPeriodSecondsBN].map(x => x.toNumber());

    // Sync time to start on next full transaction id
    // For a real setting, make sure that computer time is synced with a reliable time provider
    // Take blockchain time
    let now = await getTime();
    const startingEpoch = (Math.floor((now - firstEpochStartTs) / submitPeriodSeconds) + 1);
    let next = startingEpoch * submitPeriodSeconds + firstEpochStartTs;
    let diff = Math.floor(next - now) + 1;
    console.log(`Waiting for ${diff} seconds until first start`); 
    await sleep(diff * 1000);

    let currentEpoch = startingEpoch;
    while(true){
        // Force hardhat to mine a new block which will have an updated timestamp. if we don't hardhat timestamp will not update.
        time.advanceBlock();
        console.log("Start submit for epoch: ", currentEpoch); 
        // Prepare prices and randoms
        const randoms = symbols.map(sym => getRandom(currentEpoch, sym)); 
        // Just a mock here, real price should not be random
        const prices = symbols.map(sym => getPrice(currentEpoch, sym)); 
        const hashes = prices.map((p, i) => 
            submitPriceHash(p, randoms[i], priceProviderAccount.address)
        );
        console.log("Prices: ", prices);
        console.log("Randoms: ", randoms);
        // Submit price, on everything
        const submission = await priceSubmitter.submitPriceHashes(currentEpoch, 
            ftsoIndices, hashes, {from: priceProviderAccount.address}
        );
        expectEvent(submission, "PriceHashesSubmitted", { ftsos: ftsoAddresses, 
            epochId: currentEpoch.toString(), hashes: hashes});

        currentEpoch = currentEpoch + 1;

        now = await getTime();
        next = currentEpoch * submitPeriodSeconds + firstEpochStartTs;
        diff = Math.floor(next - now);
        console.log(`Waiting for ${diff} seconds until reveal`); 
        await sleep(diff * 1000);
        
        // Reval prices
        time.advanceBlock();
        const reveal = await priceSubmitter.revealPrices(currentEpoch - 1, ftsoIndices, prices, randoms, {from: priceProviderAccount.address});
        await expectEvent(reveal, "PricesRevealed", { ftsos: ftsoAddresses,
            epochId: (currentEpoch - 1).toString(), prices: prices.map(x => toBN(x)) });

        console.log("Revealed prices for epoch ", currentEpoch - 1);
        // start loop again, the price submission has already started
    }
}
   
main()
    .then(() => process.exit(0))
    .catch(error => {
    console.error(error);
    process.exit(1);
});

