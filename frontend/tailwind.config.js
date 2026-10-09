/** @type {import('tailwindcss').Config} */
export default {
  content: [
    "./index.html",
    "./src/**/*.{js,ts,jsx,tsx}",
  ],
  theme: {
    extend: {
      colors: {
        luxury: {
          dark: '#0a0a0a',
          card: '#141414',
          accent: '#00f2ff',
          neon: '#bc00ff'
        }
      },
      backgroundImage: {
        'luxury-gradient': 'linear-gradient(135deg, #0a0a0a 0%, #1a1a1a 100%)',
        'neon-gradient': 'linear-gradient(90deg, #00f2ff 0%, #bc00ff 100%)',
      }
    },
  },
  plugins: [],
}
