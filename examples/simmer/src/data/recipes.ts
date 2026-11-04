// Simmer's recipe library. Built into the app: a demo needs no backend for this.
//
// Ingredient lines are written the way a real recipe site writes them
// ("1 lb boneless chicken thighs", "3 cloves garlic, minced"). That is the
// point: the Mealio SDK takes them as they are.
//
// Several recipes share ingredients on purpose (onion, garlic, cilantro, limes,
// rice, parmesan), so a multi-meal cart shows Mealio merging them.

import type { ImageSourcePropType } from 'react-native';

export type Tag = 'Quick' | 'Chicken' | 'Beef' | 'Seafood' | 'Vegetarian' | 'Pasta' | 'Bowls' | 'Comfort';

export interface Ingredient {
  /** As the recipe writes it. Sent to Mealio unchanged. */
  name: string;
  /** Packages to buy, when more than one. */
  quantity?: number;
}

export interface Recipe {
  id: string;
  title: string;
  blurb: string;
  minutes: number;
  serves: number;
  tags: Tag[];
  image: ImageSourcePropType;
  ingredients: Ingredient[];
  steps: string[];
}

export const RECIPES: Recipe[] = [
  {
    id: 'lemon-garlic-salmon',
    title: 'Lemon Garlic Salmon',
    blurb: 'Crisp-skinned salmon in a lemony garlic butter, ready in 20 minutes.',
    minutes: 20,
    serves: 4,
    tags: ['Quick', 'Seafood'],
    image: require('../../assets/recipes/lemon-garlic-salmon.jpg'),
    ingredients: [
      { name: '4 salmon fillets' },
      { name: '3 tbsp butter' },
      { name: '4 cloves garlic, minced' },
      { name: '2 lemons' },
      { name: '1 bunch fresh parsley' },
      { name: '1 lb asparagus' },
      { name: 'olive oil' },
    ],
    steps: [
      'Pat the salmon dry and season with salt and pepper.',
      'Sear skin side down in a little olive oil over medium-high heat, 4 minutes. Flip.',
      'Add the butter, garlic and the juice of one lemon. Spoon the butter over the fish for 2 minutes.',
      'Roast the asparagus at 425°F with olive oil while the fish cooks, about 10 minutes.',
      'Finish with parsley and lemon wedges.',
    ],
  },
  {
    id: 'taco-salad',
    title: 'Chicken Taco Salad',
    blurb: 'Smoky chipotle chicken over crunchy greens in a crisp tortilla bowl.',
    minutes: 30,
    serves: 4,
    tags: ['Chicken', 'Bowls'],
    image: require('../../assets/recipes/taco-salad.jpg'),
    ingredients: [
      { name: '1.5 lb boneless chicken thighs' },
      { name: '1 can chipotle peppers in adobo' },
      { name: '1 yellow onion, sliced' },
      { name: '2 cloves garlic, minced' },
      { name: '1 head romaine lettuce' },
      { name: '1 pint cherry tomatoes' },
      { name: '1 cup shredded cheddar cheese' },
      { name: 'sour cream' },
      { name: '1 bunch cilantro' },
      { name: '2 limes' },
      { name: 'large flour tortillas' },
    ],
    steps: [
      'Blend two chipotles with a spoon of adobo, garlic and the juice of one lime.',
      'Brown the chicken and onion, add the chipotle sauce, cover and simmer 15 minutes. Shred.',
      'Bake tortillas over oven-safe bowls at 375°F until crisp, 8 to 10 minutes.',
      'Fill with lettuce, tomatoes, chicken and cheese. Top with sour cream and cilantro.',
    ],
  },
  {
    id: 'chicken-alfredo',
    title: 'Creamy Chicken Alfredo',
    blurb: 'Silky parmesan sauce, tender chicken and fettuccine. Pure comfort.',
    minutes: 30,
    serves: 4,
    tags: ['Chicken', 'Pasta', 'Comfort'],
    image: require('../../assets/recipes/chicken-alfredo.jpg'),
    ingredients: [
      { name: '1 lb fettuccine' },
      { name: '1 lb boneless chicken breasts' },
      { name: '2 cups heavy cream' },
      { name: '4 tbsp butter' },
      { name: '1.5 cups grated parmesan cheese' },
      { name: '3 cloves garlic, minced' },
      { name: '1 bunch fresh parsley' },
    ],
    steps: [
      'Cook the fettuccine in well-salted water. Save a cup of the pasta water.',
      'Season and sear the chicken until cooked through. Slice.',
      'Melt the butter with the garlic, add the cream and simmer 3 minutes.',
      'Whisk in the parmesan off the heat. Loosen with pasta water.',
      'Toss with the pasta and chicken. Finish with parsley.',
    ],
  },
  {
    id: 'beef-broccoli',
    title: 'Beef and Broccoli Stir-Fry',
    blurb: 'Better than takeout: glossy ginger-garlic sauce over jasmine rice.',
    minutes: 25,
    serves: 4,
    tags: ['Quick', 'Beef', 'Bowls'],
    image: require('../../assets/recipes/beef-broccoli.jpg'),
    ingredients: [
      { name: '1 lb flank steak, thinly sliced' },
      { name: '2 heads broccoli' },
      { name: '1/2 cup soy sauce' },
      { name: '3 tbsp brown sugar' },
      { name: '1 tbsp cornstarch' },
      { name: '1 piece fresh ginger' },
      { name: '4 cloves garlic, minced' },
      { name: '2 cups jasmine rice' },
      { name: 'sesame oil' },
    ],
    steps: [
      'Start the rice.',
      'Whisk the soy sauce, brown sugar, cornstarch, grated ginger and garlic with half a cup of water.',
      'Sear the beef in batches in a hot pan with sesame oil. Set aside.',
      'Stir-fry the broccoli 3 minutes, add a splash of water and cover 1 minute.',
      'Return the beef, pour in the sauce and toss until glossy. Serve over rice.',
    ],
  },
  {
    id: 'carbonara',
    title: 'Spaghetti Carbonara',
    blurb: 'Five ingredients, no cream, all Roman. Ready before the water cools.',
    minutes: 20,
    serves: 4,
    tags: ['Quick', 'Pasta'],
    image: require('../../assets/recipes/carbonara.jpg'),
    ingredients: [
      { name: '1 lb spaghetti' },
      { name: '6 oz pancetta' },
      { name: '4 large eggs' },
      { name: '1 cup grated parmesan cheese' },
      { name: 'black pepper' },
    ],
    steps: [
      'Cook the spaghetti. Save a cup of the pasta water.',
      'Crisp the pancetta in a wide pan.',
      'Whisk the eggs with the parmesan and lots of black pepper.',
      'Off the heat, toss the hot pasta with the pancetta, then the egg mixture, adding pasta water until creamy.',
    ],
  },
  {
    id: 'burrito-bowls',
    title: 'Black Bean Burrito Bowls',
    blurb: 'Cilantro-lime rice, spiced black beans and every topping you like.',
    minutes: 30,
    serves: 4,
    tags: ['Vegetarian', 'Bowls'],
    image: require('../../assets/recipes/burrito-bowls.jpg'),
    ingredients: [
      { name: '2 cups long grain white rice' },
      { name: '2 cans black beans', quantity: 2 },
      { name: '1 can corn' },
      { name: '1 yellow onion, diced' },
      { name: '2 cloves garlic, minced' },
      { name: '2 avocados', quantity: 2 },
      { name: '1 jar salsa' },
      { name: '1 bunch cilantro' },
      { name: '2 limes' },
      { name: '1 cup shredded cheddar cheese' },
    ],
    steps: [
      'Cook the rice. Stir in chopped cilantro and the juice of one lime.',
      'Soften the onion and garlic, add the beans with cumin and a splash of water. Simmer 10 minutes.',
      'Warm the corn.',
      'Build bowls: rice, beans, corn, salsa, sliced avocado and cheese.',
    ],
  },
  {
    id: 'shrimp-fried-rice',
    title: 'Shrimp Fried Rice',
    blurb: 'Day-old rice, plump shrimp and a hot pan. Dinner in 15 minutes.',
    minutes: 15,
    serves: 4,
    tags: ['Quick', 'Seafood'],
    image: require('../../assets/recipes/shrimp-fried-rice.jpg'),
    ingredients: [
      { name: '1 lb large shrimp, peeled' },
      { name: '4 cups cooked jasmine rice' },
      { name: '3 large eggs' },
      { name: '1 bag frozen peas and carrots' },
      { name: '1 bunch green onions' },
      { name: '3 tbsp soy sauce' },
      { name: '2 cloves garlic, minced' },
      { name: 'sesame oil' },
    ],
    steps: [
      'Sear the shrimp in sesame oil until pink. Set aside.',
      'Scramble the eggs in the same pan. Set aside.',
      'Fry the garlic, peas and carrots, then the rice, until it crackles.',
      'Add the soy sauce, shrimp, eggs and sliced green onions. Toss.',
    ],
  },
  {
    id: 'turkey-chili',
    title: 'Weeknight Turkey Chili',
    blurb: 'Hearty, smoky and better the next day. One pot, big batch.',
    minutes: 45,
    serves: 6,
    tags: ['Comfort'],
    image: require('../../assets/recipes/turkey-chili.jpg'),
    ingredients: [
      { name: '1 lb ground turkey' },
      { name: '1 yellow onion, diced' },
      { name: '3 cloves garlic, minced' },
      { name: '1 red bell pepper' },
      { name: '2 cans kidney beans', quantity: 2 },
      { name: '1 can fire roasted tomatoes' },
      { name: '1 can corn' },
      { name: 'chili powder' },
      { name: '1 cup shredded cheddar cheese' },
      { name: 'sour cream' },
    ],
    steps: [
      'Brown the turkey with the onion, garlic and bell pepper.',
      'Stir in 3 tbsp chili powder, then the beans, tomatoes and corn.',
      'Simmer 30 minutes, stirring now and then.',
      'Serve with cheddar and sour cream.',
    ],
  },
  {
    id: 'margherita-flatbread',
    title: 'Margherita Flatbread',
    blurb: 'Blistered tomatoes, fresh mozzarella and basil on a crisp crust.',
    minutes: 20,
    serves: 2,
    tags: ['Quick', 'Vegetarian'],
    image: require('../../assets/recipes/margherita-flatbread.jpg'),
    ingredients: [
      { name: '2 naan flatbreads' },
      { name: '8 oz fresh mozzarella' },
      { name: '1 pint cherry tomatoes' },
      { name: '1 bunch fresh basil' },
      { name: '1 jar marinara sauce' },
      { name: 'olive oil' },
    ],
    steps: [
      'Heat the oven to 450°F.',
      'Spread a thin layer of marinara on each flatbread.',
      'Top with torn mozzarella and halved tomatoes. Drizzle with olive oil.',
      'Bake 8 to 10 minutes. Finish with basil.',
    ],
  },
  {
    id: 'teriyaki-bowls',
    title: 'Teriyaki Chicken Rice Bowls',
    blurb: 'Sticky homemade teriyaki, fluffy rice and a crunch of sesame.',
    minutes: 30,
    serves: 4,
    tags: ['Chicken', 'Bowls'],
    image: require('../../assets/recipes/teriyaki-bowls.jpg'),
    ingredients: [
      { name: '1.5 lb boneless chicken thighs' },
      { name: '1/2 cup soy sauce' },
      { name: '3 tbsp honey' },
      { name: '1 piece fresh ginger' },
      { name: '3 cloves garlic, minced' },
      { name: '2 cups jasmine rice' },
      { name: '1 head broccoli' },
      { name: '1 bunch green onions' },
      { name: 'sesame seeds' },
    ],
    steps: [
      'Start the rice. Steam the broccoli.',
      'Simmer the soy sauce, honey, grated ginger and garlic until syrupy.',
      'Sear the chicken until golden, then toss in the sauce.',
      'Serve over rice with broccoli, green onions and sesame seeds.',
    ],
  },
  {
    id: 'pesto-pasta',
    title: 'Pesto Pasta with Cherry Tomatoes',
    blurb: 'Bright basil pesto and sweet tomatoes. Great warm or cold.',
    minutes: 20,
    serves: 4,
    tags: ['Quick', 'Vegetarian', 'Pasta'],
    image: require('../../assets/recipes/pesto-pasta.jpg'),
    ingredients: [
      { name: '1 lb farfalle pasta' },
      { name: '1 jar basil pesto' },
      { name: '1 pint cherry tomatoes' },
      { name: '1/2 cup grated parmesan cheese' },
      { name: '1 bag baby spinach' },
      { name: '1 lemon' },
    ],
    steps: [
      'Cook the pasta. Save half a cup of the pasta water.',
      'Toss the hot pasta with the spinach so it wilts.',
      'Stir in the pesto, halved tomatoes, parmesan and a squeeze of lemon. Loosen with pasta water.',
    ],
  },
  {
    id: 'coconut-curry',
    title: 'Thai Green Coconut Curry',
    blurb: 'Fragrant green curry with chicken and vegetables in coconut milk.',
    minutes: 35,
    serves: 4,
    tags: ['Chicken', 'Comfort'],
    image: require('../../assets/recipes/coconut-curry.jpg'),
    ingredients: [
      { name: '1.5 lb boneless chicken thighs' },
      { name: '2 cans coconut milk', quantity: 2 },
      { name: '1 jar green curry paste' },
      { name: '1 red bell pepper' },
      { name: '1 yellow onion, sliced' },
      { name: '2 cups jasmine rice' },
      { name: '1 bunch fresh basil' },
      { name: '2 limes' },
      { name: 'fish sauce' },
    ],
    steps: [
      'Start the rice.',
      'Fry 3 tbsp curry paste in a splash of coconut milk until fragrant.',
      'Add the chicken and onion and cook 5 minutes.',
      'Pour in the rest of the coconut milk and the pepper. Simmer 15 minutes.',
      'Season with fish sauce and lime. Finish with basil.',
    ],
  },
];

export const TAGS: Tag[] = ['Quick', 'Chicken', 'Beef', 'Seafood', 'Vegetarian', 'Pasta', 'Bowls', 'Comfort'];

export function recipeById(id: string): Recipe | undefined {
  return RECIPES.find((r) => r.id === id);
}

/** The shape the Mealio SDK takes. */
export function toMealioRecipe(r: Recipe) {
  return { id: r.id, title: r.title, ingredients: r.ingredients.map((i) => ({ name: i.name, ...(i.quantity ? { quantity: i.quantity } : {}) })) };
}
