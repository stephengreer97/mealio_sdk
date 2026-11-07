export * from './dist/index';
/** A cart that behaves enough like CartSession. Pass PreparedCart fields to override. */
export function mockCart(over?: Partial<import('@mealio/sdk-core').PreparedCart>): import('@mealio/sdk-core').CartSession;
