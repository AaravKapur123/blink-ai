/** @type {import('tailwindcss').Config} */
export default {
  content: [
    './index.html',
    './src/**/*.{ts,tsx}',
  ],
  theme: {
    extend: {
      fontFamily: {
        sans: ['Inter', 'ui-sans-serif', 'system-ui', 'SF Pro Text', 'SF Pro Display', 'Helvetica Neue', 'Arial', 'sans-serif']
      },
      colors: {
        bg: {
          DEFAULT: '#0B1422'
        },
        card: '#0E1C2F',
        text: '#E8F0FF',
        muted: '#A9B7D0',
        mint: '#3FE1B0',
        purple: '#B18CFF',
        amber: '#F5C56B',
        red: '#FF6B6B'
      },
      boxShadow: {
        soft: '0 10px 30px rgba(0,0,0,.35)'
      },
      borderRadius: {
        '2xl': '1rem'
      }
    },
  },
  plugins: [],
}


