# AtlasChain

A commons of attested claims — crowdsourced fact registry with challenge/vote arbitration, deployed on BOT Chain.

## Lifecycle

1. **Submit** a claim with a source URL and a submission deposit (default 0.005 BOT).
2. **Challenge window** (3 days). No challenger → anyone can `finalizeUnchallenged` and the claim is Verified; the submitter reclaims their deposit.
3. If challenged (matched deposit + reason), the claim enters **Voting window** (3 days). Anyone but the two parties may stake BOT to vote *support challenge* or *defend claim*.
4. After voting, anyone calls `resolveChallenge`. Winning party takes the loser's deposit minus a platform fee. Winning voters split the losing voters' stakes pro-rata (minus platform fee). Losing voters lose their stakes.
5. Roles collect their entitlement via `claimStake(claimId)`.

Ties favor the defender.

## Setup

```
npm install
cp .env.example .env   # add PRIVATE_KEY
npx hardhat compile
npx hardhat test
npm run deploy:testnet
```

Then paste the deployed address into `CONTRACT_ADDRESS` in `frontend/index.html`.

## Networks

| Network | ChainId | RPC | Explorer |
| --- | --- | --- | --- |
| Testnet | 968 (0x3C8) | https://rpc.bohr.life | https://scan.bohr.life |
| Mainnet | 677 (0x2A5) | https://rpc.botchain.ai | https://scan.botchain.ai |

Frontend defaults to testnet; swap the network constants block for mainnet.

## Frontend

Single-file `frontend/index.html`. Museum wall-label aesthetic — brass plaques, gallery cream, deep espresso typography. Deploy via `vercel --prod` or open the file directly with MetaMask installed.
