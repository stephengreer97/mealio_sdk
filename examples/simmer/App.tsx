import React, { useEffect } from 'react';
import { NavigationContainer, DefaultTheme } from '@react-navigation/native';
import { createNativeStackNavigator } from '@react-navigation/native-stack';
import { createBottomTabNavigator } from '@react-navigation/bottom-tabs';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { StatusBar } from 'expo-status-bar';
import * as SplashScreen from 'expo-splash-screen';
import { Ionicons } from '@expo/vector-icons';
import { useFonts, Fraunces_600SemiBold, Fraunces_700Bold } from '@expo-google-fonts/fraunces';
import { Inter_400Regular, Inter_500Medium, Inter_600SemiBold } from '@expo-google-fonts/inter';
import { SimmerProvider, useSimmer } from './src/state';
import { SimmerMealio } from './src/mealio';
import { C, F } from './src/theme';
import type { RootStack, Tabs as TabList } from './src/nav';
import DiscoverScreen from './src/screens/DiscoverScreen';
import PlanScreen from './src/screens/PlanScreen';
import SavedScreen from './src/screens/SavedScreen';
import RecipeScreen from './src/screens/RecipeScreen';
import AboutScreen from './src/screens/AboutScreen';

SplashScreen.preventAutoHideAsync().catch(() => {});

const Stack = createNativeStackNavigator<RootStack>();
const Tab = createBottomTabNavigator<TabList>();

const NAV_THEME = { ...DefaultTheme, colors: { ...DefaultTheme.colors, background: C.bg, card: C.bg, primary: C.accent, text: C.text, border: C.border } };

const ICONS: Record<keyof TabList, [keyof typeof Ionicons.glyphMap, keyof typeof Ionicons.glyphMap]> = {
  Discover: ['restaurant', 'restaurant-outline'],
  Plan: ['calendar', 'calendar-outline'],
  Saved: ['heart', 'heart-outline'],
};

function Tabs() {
  const simmer = useSimmer();
  const planned = Object.values(simmer.plan).reduce((n, ids) => n + ids.length, 0);
  return (
    <Tab.Navigator screenOptions={({ route }) => ({
      headerShown: false,
      tabBarActiveTintColor: C.accent,
      tabBarInactiveTintColor: C.muted,
      tabBarStyle: { backgroundColor: C.bg, borderTopColor: C.border },
      tabBarLabelStyle: { fontFamily: F.medium, fontSize: 11 },
      tabBarIcon: ({ focused, color, size }) => <Ionicons name={ICONS[route.name][focused ? 0 : 1]} color={color} size={size} />,
    })}>
      <Tab.Screen name="Discover" component={DiscoverScreen} />
      <Tab.Screen name="Plan" component={PlanScreen} options={{ title: 'This week', tabBarBadge: planned || undefined, tabBarBadgeStyle: { backgroundColor: C.accent } }} />
      <Tab.Screen name="Saved" component={SavedScreen} />
    </Tab.Navigator>
  );
}

function Root() {
  const { ready } = useSimmer();
  const [fonts] = useFonts({ Fraunces_600SemiBold, Fraunces_700Bold, Inter_400Regular, Inter_500Medium, Inter_600SemiBold });
  useEffect(() => { if (ready && fonts) SplashScreen.hideAsync().catch(() => {}); }, [ready, fonts]);
  if (!ready || !fonts) return null;
  return (
    <SimmerMealio>
      <NavigationContainer theme={NAV_THEME}>
        <StatusBar style="dark" />
        <Stack.Navigator screenOptions={{ headerShown: false, contentStyle: { backgroundColor: C.bg } }}>
          <Stack.Screen name="Tabs" component={Tabs} />
          <Stack.Screen name="Recipe" component={RecipeScreen} />
          <Stack.Screen name="About" component={AboutScreen} options={{ presentation: 'modal' }} />
        </Stack.Navigator>
      </NavigationContainer>
    </SimmerMealio>
  );
}

export default function App() {
  return (
    <SafeAreaProvider>
      <SimmerProvider>
        <Root />
      </SimmerProvider>
    </SafeAreaProvider>
  );
}
