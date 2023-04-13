import { ethers, network } from "hardhat";
import { expect } from 'chai';
import { loadFixture } from "ethereum-waffle";
import {
    PERMIT2_ADDRESS,
    PermitTransferFrom,
    SignatureTransfer,
    Witness
} from "@uniswap/permit2-sdk";
import { BigNumber, constants } from "ethers";

const MINIMAL_ERC20_ABI = [
    "function balanceOf(address account) external view returns (uint256)",
    "function approve(address spender, uint256 amount) external returns (bool)",
    "function transfer(address to, uint256 amount) external returns (bool)"
];

const tokenFaucetAddress = "0x60faae176336dab62e284fe19b885b095d29fb7f";
const tokenInAddress = "0x6b175474e89094c44da98b954eedeac495271d0f"; // DAI
const tokenOutAddress = "0x514910771af9ca656af840dff83e8264ecf986ca"; // LINK
const ETH = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE";
const SIG_DEADLINE = "115792089237316195423570985008687907853269984665640564039457584007913129639935";

const ZeroExchangeProxyArbitrum = "0xdef1c0ded9bec7f1a1670819833240f027b25eff"; // we use mainnet because arb forking is wonky

const testAmountIn = ethers.utils.parseEther("100");

describe("Styx Permit2 Proxy", function () {
    async function fixtures() {
        const [owner, addr1, addr2] = await ethers.getSigners();

        // Deploy Owner Helper
        const OwnerHelper = await ethers.getContractFactory("OwnerHelper");
        const ownerHelper = await OwnerHelper.deploy();
        await ownerHelper.deployed();

        const ArbAddressTable = await ethers.getContractFactory("ArbAddressTable");
        const arbAddressTable = await ArbAddressTable.deploy();
        await arbAddressTable.deployed();

        // Deploy Permit Proxy
        const PermitProxy = await ethers.getContractFactory("StyxPermitProxy");
        const permitProxy = await PermitProxy.deploy(PERMIT2_ADDRESS, arbAddressTable.address, ownerHelper.address);
        await permitProxy.deployed();

        // Deploy Utils
        const UtilsPermit = await ethers.getContractFactory("StyxUtilsPermit")
        const utilsPermit = await UtilsPermit.deploy();
        await utilsPermit.deployed();

        // Get some tokens to swap
        await network.provider.request({
            method: "hardhat_impersonateAccount",
            params: [tokenFaucetAddress],
        });
        const faucet = await ethers.getSigner(tokenFaucetAddress);

        const tokenIn = new ethers.Contract(tokenInAddress, MINIMAL_ERC20_ABI, faucet)
        const tokenInAmount = ethers.utils.parseEther("10000");
        await tokenIn.connect(faucet).transfer(addr1.address, tokenInAmount);

        const tokenOut = new ethers.Contract(tokenOutAddress, MINIMAL_ERC20_ABI, addr1)

        // Setup routers
        await ownerHelper.setAggregator(permitProxy.address, ZeroExchangeProxyArbitrum, "0")

        // Give unlimited approval to Permit2
        await tokenIn.connect(addr1).approve(PERMIT2_ADDRESS, constants.MaxInt256)

        return { tokenIn, tokenOut, addr1, permitProxy, utilsPermit, arbAddressTable, addr2 }
    }

    it("Should execute a token to token trade using 0x Exchange", async function () {
        const { tokenIn, tokenOut, arbAddressTable, utilsPermit, permitProxy, addr1 } = await loadFixture(fixtures);

        const amountInCint = await utilsPermit.compress(testAmountIn);
        // We have to use the uncompressed number for our quote and for the permit
        const amountInUncompressed = await utilsPermit.uncompress(amountInCint);

        const quoteResponse = await fetch(
            `https://api.0x.org/swap/v1/quote?buyToken=${tokenOut.address}&sellAmount=${amountInUncompressed}&sellToken=${tokenIn.address}`
        );

        await expect(quoteResponse.status).to.be.equal(200);

        const quote = await quoteResponse.json();

        // Register token Index from Arb Address Table
        await arbAddressTable.register(tokenIn.address);
        await arbAddressTable.register(tokenOut.address);

        const tokenInIndex = await arbAddressTable.lookup(tokenIn.address)
        const tokenOutIndex = await arbAddressTable.lookup(tokenOut.address)

        const currNonce = await ethers.provider.getStorageAt(permitProxy.address, ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["address", "uint256"], [addr1.address, "0x0"])))

        const permit: PermitTransferFrom = {
            permitted: {
                token: tokenIn.address,
                amount: amountInUncompressed
            },
            spender: permitProxy.address,
            nonce: parseInt(currNonce) + 1337 + 420 + 69 + 15537393,
            deadline: SIG_DEADLINE
        };

        const witness: Witness = {
            witnessTypeName: "Witness",
            witnessType: { Witness: [{ name: "swapCalldata", type: "bytes32" }] },
            witness: { swapCalldata: ethers.utils.keccak256(quote.data) }
        }

        const { chainId } = await ethers.provider.getNetwork();

        const { domain, types, values } = SignatureTransfer.getPermitData(permit, PERMIT2_ADDRESS, chainId, witness);

        const signature = await addr1._signTypedData(domain, types, values);

        const { r, s, v } = ethers.utils.splitSignature(signature);

        const [rCompact, vsCompact] = await utilsPermit.getCompactSignature(v, r, s);

        const packedData = ethers.BigNumber.from("0")
            .shl(112)
            .or(ethers.BigNumber.from(amountInCint).shl(48))
            .or(ethers.BigNumber.from(tokenInIndex).shl(24))
            .or(ethers.BigNumber.from(tokenOutIndex));

        const encoded = ethers.utils.concat([
            ethers.utils.defaultAbiCoder.encode(["uint120"], [packedData]),
            ethers.utils.defaultAbiCoder.encode(["bytes32"], [rCompact]),
            ethers.utils.defaultAbiCoder.encode(["bytes32"], [vsCompact]),
            quote.data
        ]);

        const rawTx = {
            to: permitProxy.address,
            data: encoded,
            value: quote.value
        }

        //const balTokenOutBefore = await tokenOut.balanceOf(addr1.address)

        const signedTx = await addr1.sendTransaction(rawTx)

        //const balTokenOutAfter = await tokenOut.balanceOf(addr1.address)

        //console.log(ethers.utils.formatEther(balTokenOutBefore.toString()), "balance tokenOut Before")
        //console.log(ethers.utils.formatEther(balTokenOutAfter.toString()), "balance tokenOut After")

    })

    it("Should execute a token to eth trade using 0x Exchange", async function () {
        const { tokenIn, tokenOut, arbAddressTable, utilsPermit, permitProxy, addr1 } = await loadFixture(fixtures);

        const amountInCint = await utilsPermit.compress(testAmountIn);
        // We have to use the uncompressed number for our quote and for the permit
        const amountInUncompressed = await utilsPermit.uncompress(amountInCint);

        const quoteResponse = await fetch(
            `https://api.0x.org/swap/v1/quote?buyToken=${ETH}&sellAmount=${amountInUncompressed}&sellToken=${tokenIn.address}`
        );

        await expect(quoteResponse.status).to.be.equal(200);

        const quote = await quoteResponse.json();

        // Register token Index from Arb Address Table
        await arbAddressTable.register(tokenIn.address);
        await arbAddressTable.register(ETH);

        const tokenInIndex = await arbAddressTable.lookup(tokenIn.address)
        const tokenOutIndex = await arbAddressTable.lookup(ETH)

        const currNonce = await ethers.provider.getStorageAt(permitProxy.address, ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["address", "uint256"], [addr1.address, "0x0"])))

        const permit: PermitTransferFrom = {
            permitted: {
                token: tokenIn.address,
                amount: amountInUncompressed
            },
            spender: permitProxy.address,
            nonce: parseInt(currNonce) + 1337 + 420 + 69 + 15537393,
            deadline: SIG_DEADLINE
        };

        const witness: Witness = {
            witnessTypeName: "Witness",
            witnessType: { Witness: [{ name: "swapCalldata", type: "bytes32" }] },
            witness: { swapCalldata: ethers.utils.keccak256(quote.data) }
        }

        const { chainId } = await ethers.provider.getNetwork();

        const { domain, types, values } = SignatureTransfer.getPermitData(permit, PERMIT2_ADDRESS, chainId, witness);

        const signature = await addr1._signTypedData(domain, types, values);

        const { r, s, v } = ethers.utils.splitSignature(signature);

        const [rCompact, vsCompact] = await utilsPermit.getCompactSignature(v, r, s);

        const packedData = ethers.BigNumber.from("0")
            .shl(112)
            .or(ethers.BigNumber.from(amountInCint).shl(48))
            .or(ethers.BigNumber.from(tokenInIndex).shl(24))
            .or(ethers.BigNumber.from(tokenOutIndex));

        const encoded = ethers.utils.concat([
            ethers.utils.defaultAbiCoder.encode(["uint120"], [packedData]),
            ethers.utils.defaultAbiCoder.encode(["bytes32"], [rCompact]),
            ethers.utils.defaultAbiCoder.encode(["bytes32"], [vsCompact]),
            quote.data
        ]);

        const rawTx = {
            to: permitProxy.address,
            data: encoded,
            value: quote.value
        }

        //const balEthBefore = await ethers.provider.getBalance(addr1.address)

        const signedTx = await addr1.sendTransaction(rawTx)

        //const balEthAfter = await ethers.provider.getBalance(addr1.address)

        //console.log(ethers.utils.formatEther(balEthBefore.toString()), "balance Eth Before")
        //console.log(ethers.utils.formatEther(balEthAfter.toString()), "balance Eth After")

    })

})