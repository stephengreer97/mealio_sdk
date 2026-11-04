import type { NativeStackScreenProps } from '@react-navigation/native-stack';

export type RootStack = {
  Tabs: undefined;
  Recipe: { id: string };
  About: undefined;
};

export type Tabs = {
  Discover: undefined;
  Plan: undefined;
  Saved: undefined;
};

export type RecipeProps = NativeStackScreenProps<RootStack, 'Recipe'>;
