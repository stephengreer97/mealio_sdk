import React, { useMemo, useState } from 'react';
import { FlatList, Pressable, ScrollView, StyleSheet, Text, TextInput, useWindowDimensions, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { Ionicons } from '@expo/vector-icons';
import { useNavigation } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';
import { RECIPES, TAGS, type Tag } from '../data/recipes';
import { useSimmer } from '../state';
import { C, F, R } from '../theme';
import { Chip, RecipeCard } from '../components/ui';
import type { RootStack } from '../nav';

const PAD = 20;
const GAP = 14;

export default function DiscoverScreen() {
  const nav = useNavigation<NativeStackNavigationProp<RootStack>>();
  const simmer = useSimmer();
  const { width } = useWindowDimensions();
  const [query, setQuery] = useState('');
  const [tag, setTag] = useState<Tag | null>(null);
  const cardW = (width - PAD * 2 - GAP) / 2;

  const list = useMemo(() => {
    const q = query.trim().toLowerCase();
    return RECIPES.filter((r) => (!tag || r.tags.includes(tag))
      && (!q || r.title.toLowerCase().includes(q) || r.ingredients.some((i) => i.name.toLowerCase().includes(q))));
  }, [query, tag]);

  return (
    <SafeAreaView style={s.root} edges={['top']}>
      <FlatList
        data={list}
        keyExtractor={(r) => r.id}
        numColumns={2}
        columnWrapperStyle={{ gap: GAP, paddingHorizontal: PAD }}
        keyboardShouldPersistTaps="handled"
        ListHeaderComponent={
          <View>
            <View style={s.top}>
              <Text style={s.brand}>Simmer</Text>
              <Pressable onPress={() => nav.navigate('About')} hitSlop={10} accessibilityRole="button" accessibilityLabel="About this demo">
                <Ionicons name="information-circle-outline" size={26} color={C.text} />
              </Pressable>
            </View>
            <Text style={s.hello}>What are we cooking this week?</Text>
            <View style={s.search}>
              <Ionicons name="search" size={18} color={C.muted} />
              <TextInput value={query} onChangeText={setQuery} placeholder="Search recipes or ingredients"
                placeholderTextColor={C.faint} style={s.searchInput} returnKeyType="search" />
              {query ? (
                <Pressable onPress={() => setQuery('')} hitSlop={10} accessibilityLabel="Clear search">
                  <Ionicons name="close-circle" size={18} color={C.faint} />
                </Pressable>
              ) : null}
            </View>
            <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={s.tags}>
              <Chip label="All" on={!tag} onPress={() => setTag(null)} />
              {TAGS.map((t) => <Chip key={t} label={t} on={tag === t} onPress={() => setTag(tag === t ? null : t)} />)}
            </ScrollView>
          </View>
        }
        ListEmptyComponent={<Text style={s.empty}>Nothing matches. Try another search.</Text>}
        renderItem={({ item }) => (
          <RecipeCard recipe={item} width={cardW} saved={simmer.isFavorite(item.id)}
            onToggleSave={() => simmer.toggleFavorite(item.id)} onPress={() => nav.navigate('Recipe', { id: item.id })} />
        )}
        contentContainerStyle={{ paddingBottom: 24 }}
      />
    </SafeAreaView>
  );
}

const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: C.bg },
  top: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: PAD, paddingTop: 8 },
  brand: { fontFamily: F.display, fontSize: 30, color: C.accent, letterSpacing: -0.5 },
  hello: { fontFamily: F.displaySemi, fontSize: 22, lineHeight: 28, color: C.text, paddingHorizontal: PAD, marginTop: 14 },
  search: {
    flexDirection: 'row', alignItems: 'center', gap: 8, marginHorizontal: PAD, marginTop: 16, height: 46,
    paddingHorizontal: 14, borderRadius: R.button, backgroundColor: C.surface, borderWidth: 1, borderColor: C.border,
  },
  searchInput: { flex: 1, fontFamily: F.body, fontSize: 15, color: C.text },
  tags: { gap: 8, paddingHorizontal: PAD, paddingVertical: 16 },
  empty: { fontFamily: F.body, color: C.muted, textAlign: 'center', marginTop: 40 },
});
