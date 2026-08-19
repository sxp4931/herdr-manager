import React from "react";
import { theme } from "../theme";

export const FlockMark: React.FC<{ size?: number; dim?: boolean }> = ({
  size = 20,
  dim = false,
}) => (
  <svg
    width={size}
    height={size}
    viewBox="0 0 24 24"
    fill="none"
    style={{ opacity: dim ? 0.4 : 1, flexShrink: 0 }}
  >
    <path
      d="M12 7.1 L16.6 14.9 L7.4 14.9 Z"
      stroke={theme.amber}
      strokeWidth="1.15"
      strokeLinejoin="round"
      strokeLinecap="round"
      strokeDasharray="0.2 2.1"
    />
    <circle cx="12" cy="6.4" r="2.35" fill={theme.amber} />
    <circle cx="17.1" cy="15.5" r="2.35" fill={theme.amber} />
    <circle cx="6.9" cy="15.5" r="2.35" fill={theme.amber} />
  </svg>
);
