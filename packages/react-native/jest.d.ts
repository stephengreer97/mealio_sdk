export * from './dist/index';
import type { MealioApi } from './dist/index';
import type { CartSession, PreparedCart } from '@mealio/sdk-core';

type Fn = (...args: any[]) => any;
type Resolved<T> = T extends PromiseLike<infer U> ? U : T;

/**
 * What the mock's functions are: jest.fn()s, typed without needing @types/jest,
 * so `useMealio().prepareCart.mockResolvedValue(mockCart())` type-checks under
 * @types/jest, @jest/globals or neither.
 */
export interface MealioMockFn<F extends Fn> {
  (...args: Parameters<F>): ReturnType<F>;
  mock: { calls: Parameters<F>[]; results: Array<{ type: 'return' | 'throw' | 'incomplete'; value: any }>; instances: any[]; lastCall?: Parameters<F> };
  mockImplementation(fn: F): this;
  mockImplementationOnce(fn: F): this;
  mockReturnValue(value: ReturnType<F>): this;
  mockReturnValueOnce(value: ReturnType<F>): this;
  mockResolvedValue(value: Resolved<ReturnType<F>>): this;
  mockResolvedValueOnce(value: Resolved<ReturnType<F>>): this;
  mockRejectedValue(value: unknown): this;
  mockRejectedValueOnce(value: unknown): this;
  mockClear(): this;
  mockReset(): this;
  mockRestore(): void;
  getMockName(): string;
  mockName(name: string): this;
}

/** MealioApi with every function a mock. */
export type MockedMealioApi = {
  [K in keyof MealioApi]: NonNullable<MealioApi[K]> extends Fn ? MealioMockFn<NonNullable<MealioApi[K]>> : MealioApi[K];
};

/** The one object every useMealio() returns. Its functions are jest mocks. */
export function useMealio(): MockedMealioApi;
/** A cart that behaves enough like CartSession. Pass PreparedCart fields to override. */
export function mockCart(over?: Partial<PreparedCart>): CartSession;
/** Sign a user in (an id), out (null: hasUser is false, the button asks for sign-in), or stop tracking (undefined). */
export function setMockUser(id: string | null | undefined): void;
/** Default answers, no recorded calls, a signed-in user. Runs after every test by itself (see setupMealioMock). */
export function resetMealioMock(): void;
/**
 * Register the after-each reset. Loaded at a test file's top level the mock
 * does this itself; call it from a setup file (setupFilesAfterEnv) when the
 * mock may first load inside a test. False where no hook can be added.
 */
export function setupMealioMock(): boolean;
