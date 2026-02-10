export interface TreeNode {
  name: string;
  path: string;
  size: number;
  type: "file" | "directory";
  extension?: string;
  children?: TreeNode[];
  truncated?: boolean;
}
