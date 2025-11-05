# LZ Scanner

## Summary
Frax regularly scans LayerZero configurations of its' OFTs to ensure the protocol runs as exepcted.  During these scans, current configurations are compared to prior configuration and a change between the two configs will prompt a notification to the Frax team.

## Current Pathways
There are two types of pathways: `Send` and `Receive`. On either of these pathways, OFT tokens can be burned or minted, respectively.

### Send Pathway
- OFT on Chain A has the correct Send Library to Chain B
- OFT on Chain A has a non-zero peer address to Chain B

### Receive Pathway
- OFT on Chain A has the correct Receive Library to Chain B
- OFT on Chain A has a non-zero peer address to Chain B

