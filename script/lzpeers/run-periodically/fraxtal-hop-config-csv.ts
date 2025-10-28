import { chains } from '../chains'
import FRAXTAL_HOP_ABI from '../abis/FRAXTAL_HOP.json'

interface HopConfig {
    chain: string
    blockNumber: string
    peerId: string
    remoteHop: string
}

const MSIG_ABI = [
    {
        inputs: [],
        name: 'getOwners',
        outputs: [
            {
                internalType: 'address[]',
                name: '',
                type: 'address[]',
            },
        ],
        stateMutability: 'view',
        type: 'function',
    },
    {
        inputs: [],
        name: 'getThreshold',
        outputs: [
            {
                internalType: 'uint256',
                name: '',
                type: 'uint256',
            },
        ],
        stateMutability: 'view',
        type: 'function',
    },
]

async function main() {

    // get fraxtal hop config
    const blockNumber = await chains["fraxtal"].client.getBlockNumber()
    const endpoint = await chains["fraxtal"].client.readContract({
        address: chains["fraxtal"].hop,
        abi: FRAXTAL_HOP_ABI,
        functionName: 'ENDPOINT',
        blockNumber,
    })
    const owner = await chains["fraxtal"].client.readContract({
        address: chains["fraxtal"].hop,
        abi: FRAXTAL_HOP_ABI,
        functionName: 'owner',
        blockNumber,
    })
    const signers = await chains["fraxtal"].client.readContract({
        address: owner,
        abi: MSIG_ABI,
        functionName: 'getOwners',
        blockNumber,
    })

    const threshold = await chains["fraxtal"].client.readContract({
        address: owner,
        abi: MSIG_ABI,
        functionName: 'getThreshold',
        blockNumber,
    })
    console.log("blockNumber,endpoint,owner,threshold,signers");
    console.log(`${blockNumber},${endpoint},${owner},${threshold},${signers}`)
    const hopConfigs: HopConfig[] = []
    const chainProcessingPromises = Object.keys(chains).map(async (chainName) => {
        const chainResults: HopConfig[] = []
        if (
            chainName !== 'fraxtal'
        ) {
            const remoteHop = await chains["fraxtal"].client.readContract({
                address: chains["fraxtal"].hop,
                abi: FRAXTAL_HOP_ABI,
                functionName: 'remoteHop',
                args:[chains[chainName].peerId],
                blockNumber,
            })

            hopConfigs.push({
                chain: chainName,
                blockNumber: blockNumber.toString(),
                remoteHop: remoteHop,
                peerId: chains[chainName].peerId.toString()
            })
        }
        return chainResults
    })
    const hopConfigResults = await Promise.all(chainProcessingPromises)

    for (const hopConfigResult of hopConfigResults) {
        hopConfigs.push(...hopConfigResult)
    }

    console.log("Chain,Blocknumber,RemoteHop,PeerId")
    hopConfigs.forEach((hopConfig) => {
        console.log(`${hopConfig.chain},${hopConfig.blockNumber},${hopConfig.remoteHop},${hopConfig.peerId}`)
    })
}

main().catch(console.error)
