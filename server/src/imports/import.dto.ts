import { Transform, Type } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayMinSize,
  ArrayUnique,
  IsArray,
  IsBoolean,
  IsIn,
  IsInt,
  IsString,
  IsUUID,
  Length,
  Matches,
  Max,
  MaxLength,
  Min,
  ValidateIf,
  ValidateNested,
  ValidationArguments,
  ValidatorConstraint,
  ValidatorConstraintInterface,
  Validate
} from 'class-validator';
import { MAX_UPLOAD_PART_COUNT } from './import.contracts';

const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const QUESTION_TYPES = ['single_choice', 'blank', 'short_answer', 'unknown'] as const;

function trimString({ value }: { value: unknown }): unknown {
  return typeof value === 'string' ? value.trim() : value;
}

@ValidatorConstraint({ name: 'absolutePdfPageRange', async: false })
class AbsolutePdfPageRangeConstraint implements ValidatorConstraintInterface {
  validate(pageEnd: unknown, arguments_: ValidationArguments): boolean {
    const pageStart = (arguments_.object as { pageStart?: unknown }).pageStart;
    return Number.isInteger(pageStart) && Number.isInteger(pageEnd) &&
      (pageEnd as number) >= (pageStart as number) &&
      (pageEnd as number) - (pageStart as number) + 1 <= 20;
  }

  defaultMessage(): string {
    return 'pageEnd must be an absolute PDF page at or after pageStart, spanning at most 20 pages';
  }
}

@ValidatorConstraint({ name: 'boundedQuestionOptions', async: false })
class BoundedQuestionOptionsConstraint implements ValidatorConstraintInterface {
  validate(value: unknown): boolean {
    if (value === null || value === undefined) return true;
    if (typeof value !== 'object' || Array.isArray(value)) return false;
    const entries = Object.entries(value as Record<string, unknown>);
    return entries.length <= 10 && entries.every(([key, option]) =>
      /^[A-Za-z0-9]{1,8}$/.test(key) && typeof option === 'string' &&
      option.trim().length >= 1 && option.length <= 2_000
    );
  }

  defaultMessage(): string {
    return 'options must contain at most 10 short keys with non-empty string values';
  }
}

@ValidatorConstraint({ name: 'requiredNullableQuestionOptions', async: false })
class RequiredNullableQuestionOptionsConstraint implements ValidatorConstraintInterface {
  validate(value: unknown): boolean {
    return value === null || (value !== undefined && typeof value === 'object' && !Array.isArray(value));
  }

  defaultMessage(): string {
    return 'options must be present and must be an object or null';
  }
}

export class CreatePdfImportDto {
  @Transform(trimString)
  @IsString()
  @Length(1, 255)
  bankName!: string;

  @Transform(trimString)
  @IsString()
  @Length(1, 64)
  subject!: string;

  @IsInt()
  @Min(1)
  @Max(20)
  pageStart!: number;

  @IsInt()
  @Min(1)
  @Max(20)
  @Validate(AbsolutePdfPageRangeConstraint)
  pageEnd!: number;

  @IsInt()
  @Min(1)
  @Max(209_715_200)
  sourceSize!: number;

  @IsString()
  @Matches(SHA256_PATTERN)
  sourceSha256!: string;
}

export class CompletePdfImportDto {
  @IsInt()
  @Min(1)
  @Max(MAX_UPLOAD_PART_COUNT)
  partCount!: number;

  @IsString()
  @Matches(SHA256_PATTERN)
  sourceSha256!: string;
}

export class ImportJobParamsDto {
  @IsUUID()
  jobId!: string;
}

export class ImportPartParamsDto extends ImportJobParamsDto {
  @Type(() => Number)
  @IsInt()
  @Min(0)
  partIndex!: number;
}

export class ImportArtifactParamsDto extends ImportJobParamsDto {
  @IsUUID()
  artifactId!: string;
}

export class ConfirmImportQuestionDto {
  @IsUUID()
  draftQuestionId!: string;

  @IsString()
  @IsIn(QUESTION_TYPES)
  type!: string;

  @Transform(trimString)
  @IsString()
  @Length(1, 20_000)
  question!: string;

  @Validate(RequiredNullableQuestionOptionsConstraint)
  @Validate(BoundedQuestionOptionsConstraint)
  options!: Record<string, string> | null;

  @ValidateIf((_object, value) => value !== null)
  @IsString()
  @MaxLength(20_000)
  answer!: string | null;

  @ValidateIf((_object, value) => value !== null)
  @IsString()
  @MaxLength(40_000)
  analysis!: string | null;

  @IsBoolean()
  reviewed!: boolean;
}

export class ConfirmPdfImportDto {
  @Transform(trimString)
  @IsString()
  @Length(1, 255)
  bankName!: string;

  @Transform(trimString)
  @IsString()
  @Length(1, 64)
  subject!: string;

  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(500)
  @ArrayUnique((question: ConfirmImportQuestionDto) => question.draftQuestionId)
  @ValidateNested({ each: true })
  @Type(() => ConfirmImportQuestionDto)
  questions!: ConfirmImportQuestionDto[];
}

export class AckImportArtifactsDto {
  @IsArray()
  @ArrayMaxSize(500)
  @ArrayUnique()
  @IsUUID(undefined, { each: true })
  artifactIds!: string[];
}
