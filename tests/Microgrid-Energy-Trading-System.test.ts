import { Clarinet, Tx, Chain, Account, types } from '@stacks/transactions';
Clarinet.test({
  name: "Ensure producer registration works",
  async fn(chain: Chain, accounts: Map<string, Account>) {
    const deployer = accounts.get("deployer")!;
    let block = chain.mineBlock([
      Tx.contractCall("microgrid-energy-trading", "register-producer",
        [types.uint(100), types.uint(10)], deployer.address)
    ]);
    block.receipts[0].result.expectOk();
  },
});

Clarinet.test({
  name: "Ensure trade creation and acceptance works",
  async fn(chain: Chain, accounts: Map<string, Account>) {
    const deployer = accounts.get("deployer")!;
    const buyer = accounts.get("wallet_1")!;

    let block = chain.mineBlock([
      Tx.contractCall("microgrid-energy-trading", "register-producer",
        [types.uint(100), types.uint(10)], deployer.address),
      Tx.contractCall("microgrid-energy-trading", "create-trade",
        [types.principal(deployer.address), types.uint(50)], buyer.address),
      Tx.contractCall("microgrid-energy-trading", "accept-trade",
        [types.uint(1), types.principal(deployer.address)], buyer.address)
    ]);

    block.receipts.forEach((receipt: any) => {
      receipt.result.expectOk();
    });
  },
});