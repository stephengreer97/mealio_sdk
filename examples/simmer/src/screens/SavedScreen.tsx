import React from 'react';
import { FlatList, StyleSheet, Text, useWindowDimensions, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { Ionicons } from '@expo/vector-icons';
import { useNavigation } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';
import { RECIPES } from '../data/recipes';
import { useSimmer } from '../state';
import { C, F } from '../theme';
import { RecipeCard } from '../components/ui';
import type { RootStack } from '../nav';

export default function SavedScreen() {
  const nav = useNavigation<NativeStackNavigationProp<RootStack>>();
  const simmer = useSimmer();
  const { width } = useWindowDimensions();
  const cardW = (width - 40 - 14) / 2;
  const list = RECIPES.filter((r) => simmer.favorites.includes(r.id));

  return (
    <SafeAreaView style={s.root} edges={['top']}>
      <Text style={s.title}>Saved</Text>
      <FlatList
        data={list}
        keyExtractor={(r) => r.id}
        numColumns={2}
        columnWrapperStyle={{ gap: 14, paddingHorizontal: 20 }}
        contentContainerStyle={{ paddingTop: 12, paddingBottom: 24, flexGrow: 1 }}
        ListEmptyComponent={
          <View style={s.empty}>
            <Ionicons name="heart-outline" size={40} color={C.faint} />
            <Text style={s.emptyText}>Tap the heart on a recipe to keep it here.</Text>
          </View>
        }
        renderItem={({ item }) => (
          <RecipeCard recipe={item} width={cardW} saved onToggleSave={() => simmer.toggleFavorite(item.id)}
            onPress={() => nav.navigate('Recipe', { id: item.id })} />
        )}
      />
    </SafeAreaView>
  );
}

const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: C.bg },
  title: { fontFamily: F.display, fontSize: 28, color: C.text, paddingHorizontal: 20, paddingTop: 12 },
  empty: { flex: 1, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 40, paddingBottom: 80 },
  emptyText: { fontFamily: F.body, fontSize: 15, color: C.muted, textAlign: 'center', marginTop: 12 },
});
