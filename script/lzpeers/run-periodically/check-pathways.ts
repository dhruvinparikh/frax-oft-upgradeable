import { getAddress } from "viem"
import { chains } from "../chains"
// import { aptosMovementOFTs, ofts, solanaOFTs } from "../oft"
import { solanaOFTs, ofts } from '../oft'

import ENDPOINTV2_ABI from "../abis/ENDPOINTV2_ABI.json"
import fs from 'fs'
import path from "path"

const bytes32Zero = '0x0000000000000000000000000000000000000000000000000000000000000000'

interface OFTPathwayStatus {
    [chainName: string]: {
        peers: boolean[];
        sendLibSet: boolean[];
        receiveLibSet: boolean[];
    }
}

function generateCSVs(
    oftSymbol: string,
    oftPathwayStatus: OFTPathwayStatus
) {

    let chainNames = Object.keys(oftPathwayStatus)

    // init an array for the csv data
    let sendCsv = []
    let receiveCsv = []

    // create the header row
    let headerRow = ['']
    headerRow.push(...chainNames) // add all chains as columns
    sendCsv.push(headerRow.join(',')) // add header to csv data
    receiveCsv.push(headerRow.join(',')) // add header to csv data

    // loop through each chain and create the rows
    chainNames.forEach(chainName => {
        let sendRow = [chainName] // start row with the chain name
        let receiveRow = [chainName]

        // for each other chain, add the status
        for (let i=0; i < chainNames.length; i++) {
            if (oftPathwayStatus[chainName].peers[i] && oftPathwayStatus[chainName].sendLibSet[i]) {
                sendRow.push("x");
            } else {
                sendRow.push("-");
            }

            if (oftPathwayStatus[chainName].peers[i] && oftPathwayStatus[chainName].receiveLibSet[i]) {
                receiveRow.push("x");
            } else {
                receiveRow.push("-");
            }
        }
        sendCsv.push(sendRow.join(',')) // add the row to CSV data
        receiveCsv.push(receiveRow.join(','))
    })

    // join all rows with new line character to form the final CSV string
    fs.writeFileSync(
        path.join(__dirname, `./check-pathways/${oftSymbol}-send-pathways.csv`),
        sendCsv.join("\n")
    )
    fs.writeFileSync(
        path.join(__dirname, `./check-pathways/${oftSymbol}-receive-pathways.csv`),
        receiveCsv.join("\n")
    )
}


async function main() {
    const chainNames = Object.keys(chains)
    
    // Loop through each token: TODO- dynamic if token added later
    for (const oftSymbol of Object.keys(solanaOFTs)) {
        
        let pathwayStatus: OFTPathwayStatus = {}

        // Loop through each chain
        for (const srcChain of chainNames) {

            pathwayStatus[srcChain] = {
                peers: [] as boolean[],
                sendLibSet: [] as boolean[],
                receiveLibSet: [] as boolean[]
            }
            
            if (srcChain === 'solana') {
                // TODO
            } else if (srcChain === 'aptos' || srcChain === 'movement') {
                // TODO
            } else {
                // EVM
                
                // 1. generate multicalls

                // multicall arrays
                let peerMulticalls: any[] = []
                let sendLibMulticalls: any[] = []
                let receiveLibMulticalls: any[] = []

                // loop through each destination chain
                for (const dstChain of chainNames) {
                    peerMulticalls.push({
                        address: ofts[srcChain][oftSymbol].address,
                        abi: ofts[srcChain][oftSymbol].abi,
                        functionName: 'peers',
                        args: [chains[dstChain].peerId]
                    })
                    sendLibMulticalls.push({
                        address: chains[srcChain].endpoint,
                        abi: ENDPOINTV2_ABI,
                        functionName: 'getSendLibrary',
                        args: [ofts[srcChain][oftSymbol].address, chains[dstChain].peerId]
                    })
                    receiveLibMulticalls.push({
                        address: chains[srcChain].endpoint,
                        abi: ENDPOINTV2_ABI,
                        functionName: 'getReceiveLibrary',
                        args: [ofts[srcChain][oftSymbol].address, chains[dstChain].peerId]
                    })
                }

                // 2. execute multicalls
                const peersResults = await chains[srcChain].client.multicall({
                    contracts: peerMulticalls,
                })
                const sendLibResults = await chains[srcChain].client.multicall({
                    contracts: sendLibMulticalls,
                })
                const receiveLibResults = await chains[srcChain].client.multicall({
                    contracts: receiveLibMulticalls,
                })

                // 3. loop through results, append to arrays
                for (let i=0; i < peersResults.length; i++) {
                    if (peersResults[i].status === 'success' && peersResults[i].result !== bytes32Zero) {
                        // console.log(`peer: ${oftSymbol}: ${srcChain} => ${chainNames[i]}`)
                        pathwayStatus[srcChain].peers.push(true);
                    } else {
                        pathwayStatus[srcChain].peers.push(false);
                    }
                    if (
                        sendLibResults[i].status === 'success' &&
                        getAddress('0x' + sendLibResults[i].result.slice(-40)) === getAddress(chains[srcChain].sendLib302)
                    ) {
                        pathwayStatus[srcChain].sendLibSet.push(true);
                    } else {
                        pathwayStatus[srcChain].sendLibSet.push(false);
                    }
                    
                    if (
                        receiveLibResults[i].status === 'success' &&
                        getAddress(receiveLibResults[i].result.slice(-40).at(0)) === getAddress(chains[srcChain].receiveLib302)
                    ) {
                        pathwayStatus[srcChain].receiveLibSet.push(true);
                    } else {
                        pathwayStatus[srcChain].receiveLibSet.push(false);
                    }
                }
                console.log(`Completed checks for ${oftSymbol} on ${srcChain}`)
            }
        }
        console.log(`Generating CSVs for ${oftSymbol}`)
        generateCSVs(oftSymbol, pathwayStatus);
    }


}

main().catch(console.error)