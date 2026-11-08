import React from 'react';
const host = (n: string) => React.forwardRef((p: any, r: any) => React.createElement(n, { ...p, ref: r }));
export const View = host('View'), Text = host('Text'), Pressable = host('Pressable'), ScrollView = host('ScrollView'),
  TextInput = host('TextInput'), Image = host('Image'), ActivityIndicator = host('ActivityIndicator'),
  KeyboardAvoidingView = host('KeyboardAvoidingView');
// No SafeAreaView: React Native deprecated it, and the SDK must not use it.
export const StatusBar = { currentHeight: 24 };
// Like RN: an invisible Modal renders nothing.
export const Modal = (p: any) => (p.visible ? React.createElement('Modal', p) : null);
export const Platform = { OS: 'android' };
export const StyleSheet = { create: (x: any) => x, hairlineWidth: 1 };
export const useColorScheme = () => 'light';
