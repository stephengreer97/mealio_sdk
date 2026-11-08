export * from './dist/index';
/** A cart that behaves enough like CartSession. Pass PreparedCart fields to override. */
export function mockCart(over?: Partial<import('@mealio/sdk-core').PreparedCart>): import('@mealio/sdk-core').CartSession;
/** Sign a user in (an id), out (null: hasUser is false, the button asks for sign-in), or stop tracking (undefined). */
export function setMockUser(id: string | null | undefined): void;
/** Default answers, no recorded calls, a signed-in user. Runs after every test by itself when Jest's afterEach exists. */
export function resetMealioMock(): void;
