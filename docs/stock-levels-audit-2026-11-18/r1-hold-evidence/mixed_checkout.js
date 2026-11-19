// Runs the REAL R1 src/inventory.js (stock-phase1 worktree) for one mixed checkout and prints the answer + Sheet effect.
'use strict';
const path = require('node:path');
const BACKEND = process.argv[2];
const { createSheet, loadInventory, PARTS } = require(path.join(BACKEND, 'test', 'stock_fakes.js'));
(async () => {
  const sheet = createSheet();
  sheet.reset([PARTS.SEAL, PARTS.KEYPAD]);
  const inv = loadInventory({ sheet });
  const body = { techName: 'Brett Miller', date: '11/19/2026', items: [
    { name: "Stop Mold | 7' White", qtyUsed: 2, jobNumber: '4001' },
    { name: 'Keypad | Genie', qtyUsed: 1, jobNumber: '4001' },
    { name: 'Keypad | Genie', qtyUsed: 1, jobNumber: '4002' } ] };
  const r = await inv.call('POST', '/checkout_inventory', { body });
  console.log('HTTP', r.status);
  console.log('ANSWER', JSON.stringify(r.body));
  console.log('Weather Seal | Stop Mold | 7\' White:', sheet.qty(PARTS.SEAL[1]), '(was 60.00)');
  console.log('Keypad | Genie:', sheet.qty(PARTS.KEYPAD[1]), '(was 10.00)');
  console.log('PickedItems rows appended:', JSON.stringify(sheet.logRows()));
})();
