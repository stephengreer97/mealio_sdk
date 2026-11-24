// A missing item needs a decision (2026-11-24). An item missing from the add
// (a usual out of stock or gone, an item never chosen, one the store does not
// have) must be picked or deselected before the drop-in adds, so nobody finds
// an ingredient missing at pickup they never chose to leave out.
import { describe, it, expect } from 'vitest';
import { CartSession } from '../src';

const item = (key: string, status: string, over: Record<string, unknown> = {}) => ({
  key, ingredient: key, quantity: 1, status, selectedId: null, remembered: null,
  options: [{ id: `${key}-1`, name: `${key} one` }], ...over,
});
const prepared = () => ({
  cartId: 'c', store: 'heb', ready: [], needsChoice: [], unavailable: [],
  items: [
    item('onion', 'remembered', { selectedId: 'onion-1', remembered: { id: 'onion-1', name: 'onion one' } }),
    item('spinach', 'remembered_unavailable', { remembered: { id: 'spinach-0', name: 'Baby spinach' } }),
    item('garlic', 'choose'),
    item('saffron', 'unavailable', { options: [] }),
    item('salt', 'choose', { startUnchecked: true }),
  ],
}) as any;

describe('a missing item needs a decision', () => {
  it('waits on every unpicked item except a remembered one and a startUnchecked one', () => {
    const cs = new CartSession({} as any, prepared());
    expect(cs.undecided()).toEqual(['spinach', 'garlic', 'saffron']);
    expect(cs.needsDecision('onion')).toBe(false);
    expect(cs.needsDecision('salt')).toBe(false);
    expect(cs.needsDecision('nope')).toBe(false);
  });

  it('deselect settles an item, and undoDeselect brings it back', () => {
    const cs = new CartSession({} as any, prepared());
    cs.deselect('spinach');
    expect(cs.isDeselected('spinach')).toBe(true);
    expect(cs.undecided()).toEqual(['garlic', 'saffron']);
    cs.undoDeselect('spinach');
    expect(cs.isDeselected('spinach')).toBe(false);
    expect(cs.undecided()).toEqual(['spinach', 'garlic', 'saffron']);
  });

  it('a pick settles an item and clears a deselect', () => {
    const cs = new CartSession({} as any, prepared());
    cs.deselect('garlic');
    cs.select('garlic', 'garlic-1');
    expect(cs.isDeselected('garlic')).toBe(false);
    expect(cs.needsDecision('garlic')).toBe(false);
  });

  it('unticking a pick is a decision too, and sends nothing for the item', () => {
    const cs = new CartSession({} as any, prepared());
    cs.select('garlic', 'garlic-1');
    cs.deselect('garlic');
    expect(cs.needsDecision('garlic')).toBe(false);
    expect(cs.selections().find((s) => s.key === 'garlic')!.productId).toBeNull();
  });

  it('restorePicks carries a deselect over, and nothing the user did not decide', async () => {
    const from = new CartSession({} as any, prepared());
    from.deselect('spinach');
    const to = new CartSession({} as any, { ...prepared(), cartId: 'c2' });
    await to.restorePicks(from);
    expect(to.isDeselected('spinach')).toBe(true);
    expect(to.undecided()).toEqual(['garlic', 'saffron']);
  });
});

describe('items left off by default', () => {
  it('lists startUnchecked items not selected, in order, and drops one once selected', () => {
    const p = prepared();
    p.items.push(item('pepper', 'remembered', { startUnchecked: true, selectedId: 'pepper-1', remembered: { id: 'pepper-1', name: 'pepper one' } }));
    const cs = new CartSession({} as any, p);
    expect(cs.uncheckedByDefault()).toEqual(['salt', 'pepper']);
    cs.select('pepper', 'pepper-1');
    expect(cs.uncheckedByDefault()).toEqual(['salt']);
  });
});
