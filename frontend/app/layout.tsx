import type { Metadata } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: 'Cairox - Ecosystem Prediction Markets',
  description: 'Trade YES/NO tokens on Starknet ecosystem analytics predictions',
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
