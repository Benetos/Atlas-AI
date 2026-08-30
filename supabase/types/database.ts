export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.5"
  }
  public: {
    Tables: {
      nms_assets: {
        Row: {
          byte_size: number | null
          content_sha256: string | null
          mime_type: string
          referenced_by: Json
          source_commit_sha: string
          source_path: string
          status: string
          storage_bucket: string | null
          storage_path: string | null
          updated_at: string
          upstream_png_path: string | null
        }
        Insert: {
          byte_size?: number | null
          content_sha256?: string | null
          mime_type?: string
          referenced_by?: Json
          source_commit_sha: string
          source_path: string
          status?: string
          storage_bucket?: string | null
          storage_path?: string | null
          updated_at?: string
          upstream_png_path?: string | null
        }
        Update: {
          byte_size?: number | null
          content_sha256?: string | null
          mime_type?: string
          referenced_by?: Json
          source_commit_sha?: string
          source_path?: string
          status?: string
          storage_bucket?: string | null
          storage_path?: string | null
          updated_at?: string
          upstream_png_path?: string | null
        }
        Relationships: []
      }
      nms_content_records: {
        Row: {
          dataset: string
          display_name: string | null
          external_id: string
          icon_source_path: string | null
          payload: Json
          source_commit_sha: string
          source_ordinal: number
          updated_at: string
        }
        Insert: {
          dataset: string
          display_name?: string | null
          external_id: string
          icon_source_path?: string | null
          payload: Json
          source_commit_sha: string
          source_ordinal: number
          updated_at?: string
        }
        Update: {
          dataset?: string
          display_name?: string | null
          external_id?: string
          icon_source_path?: string | null
          payload?: Json
          source_commit_sha?: string
          source_ordinal?: number
          updated_at?: string
        }
        Relationships: []
      }
      nms_entities: {
        Row: {
          attributes: Json
          base_value: number | null
          category: string | null
          color_a: number | null
          color_b: number | null
          color_g: number | null
          color_r: number | null
          description: string | null
          description_id: string | null
          display_name: string | null
          entity_type: string
          game_id: string
          icon_source_path: string | null
          icon_storage_path: string | null
          legality: string | null
          name: string | null
          name_id: string | null
          name_lower_id: string | null
          rarity: string | null
          search_vector: unknown
          source_commit_sha: string
          source_dataset: string
          subcategory: string | null
          subtitle: string | null
          subtitle_id: string | null
          updated_at: string
        }
        Insert: {
          attributes?: Json
          base_value?: number | null
          category?: string | null
          color_a?: number | null
          color_b?: number | null
          color_g?: number | null
          color_r?: number | null
          description?: string | null
          description_id?: string | null
          display_name?: string | null
          entity_type: string
          game_id: string
          icon_source_path?: string | null
          icon_storage_path?: string | null
          legality?: string | null
          name?: string | null
          name_id?: string | null
          name_lower_id?: string | null
          rarity?: string | null
          search_vector?: unknown
          source_commit_sha: string
          source_dataset: string
          subcategory?: string | null
          subtitle?: string | null
          subtitle_id?: string | null
          updated_at?: string
        }
        Update: {
          attributes?: Json
          base_value?: number | null
          category?: string | null
          color_a?: number | null
          color_b?: number | null
          color_g?: number | null
          color_r?: number | null
          description?: string | null
          description_id?: string | null
          display_name?: string | null
          entity_type?: string
          game_id?: string
          icon_source_path?: string | null
          icon_storage_path?: string | null
          legality?: string | null
          name?: string | null
          name_id?: string | null
          name_lower_id?: string | null
          rarity?: string | null
          search_vector?: unknown
          source_commit_sha?: string
          source_dataset?: string
          subcategory?: string | null
          subtitle?: string | null
          subtitle_id?: string | null
          updated_at?: string
        }
        Relationships: []
      }
      nms_localizations: {
        Row: {
          is_preferred: boolean
          locale: string
          localization_id: string
          source_commit_sha: string
          source_ordinal: number
          value: string
        }
        Insert: {
          is_preferred?: boolean
          locale?: string
          localization_id: string
          source_commit_sha: string
          source_ordinal: number
          value: string
        }
        Update: {
          is_preferred?: boolean
          locale?: string
          localization_id?: string
          source_commit_sha?: string
          source_ordinal?: number
          value?: string
        }
        Relationships: []
      }
      nms_recipe_ingredients: {
        Row: {
          amount: number | null
          attributes: Json
          ingredient_entity_type: string
          ingredient_game_id: string
          position: number
          recipe_id: string
          source_commit_sha: string
        }
        Insert: {
          amount?: number | null
          attributes?: Json
          ingredient_entity_type: string
          ingredient_game_id: string
          position: number
          recipe_id: string
          source_commit_sha: string
        }
        Update: {
          amount?: number | null
          attributes?: Json
          ingredient_entity_type?: string
          ingredient_game_id?: string
          position?: number
          recipe_id?: string
          source_commit_sha?: string
        }
        Relationships: [
          {
            foreignKeyName: "nms_recipe_ingredients_ingredient_entity_type_ingredient_g_fkey"
            columns: ["ingredient_entity_type", "ingredient_game_id"]
            isOneToOne: false
            referencedRelation: "nms_entities"
            referencedColumns: ["entity_type", "game_id"]
          },
          {
            foreignKeyName: "nms_recipe_ingredients_recipe_id_fkey"
            columns: ["recipe_id"]
            isOneToOne: false
            referencedRelation: "nms_recipes"
            referencedColumns: ["recipe_id"]
          },
        ]
      }
      nms_recipes: {
        Row: {
          attributes: Json
          output_amount: number | null
          output_entity_type: string
          output_game_id: string
          recipe_id: string
          recipe_kind: string
          recipe_name: string | null
          recipe_type: string | null
          source_commit_sha: string
          source_ordinal: number
          time_seconds: number | null
        }
        Insert: {
          attributes?: Json
          output_amount?: number | null
          output_entity_type: string
          output_game_id: string
          recipe_id: string
          recipe_kind: string
          recipe_name?: string | null
          recipe_type?: string | null
          source_commit_sha: string
          source_ordinal: number
          time_seconds?: number | null
        }
        Update: {
          attributes?: Json
          output_amount?: number | null
          output_entity_type?: string
          output_game_id?: string
          recipe_id?: string
          recipe_kind?: string
          recipe_name?: string | null
          recipe_type?: string | null
          source_commit_sha?: string
          source_ordinal?: number
          time_seconds?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "nms_recipes_output_entity_type_output_game_id_fkey"
            columns: ["output_entity_type", "output_game_id"]
            isOneToOne: false
            referencedRelation: "nms_entities"
            referencedColumns: ["entity_type", "game_id"]
          },
        ]
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      [_ in never]: never
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {},
  },
} as const
